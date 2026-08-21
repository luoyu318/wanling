import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../widgets/markdown_block_spacing.dart';
import '../widgets/markdown_config.dart';
import '../widgets/markdown_latex.dart';
import '../widgets/markdown_strong.dart';
import '../widgets/markdown_view.dart';
import 'package:wanling_core/utils/duration_format.dart';
import 'package:wanling_core/utils/icon_font.dart';
import 'message_content_renderer.dart';

/// MarkdownView 共用的 generators（与 builtin_renderers.dart 一致，改时同步）。
final List<SpanNodeGeneratorWithTag> _markdownGenerators = [
  latexGenerator,
  strongGenerator,
  hrSpacingGenerator,
  ...headingSpacingGenerators(),
];

/// AI 思考链渲染器：读 [MessageRenderContext.isStreaming] 分发到两态子 widget。
/// - 流式态(isStreaming=true 且 data.finished != true)：✨ 闪烁动画 + text 非空时
///   显示真实思考文本（post_api_request 段落级增量），空文本才显示「正在思考...」
/// - 终态(isStreaming=false 或 data.finished == true)：✨ 淡化 + 真实 text 预览
///
/// data.finished(元素级终态标记,方案 B):聚合卡整体 generating 期间(isStreaming=true)
/// 元素可能已终态(plugin 终态 append 带 finished:true)。此时即使卡片 state 仍是
/// generating,reasoning 也显示真实内容而非「思考中」动画——否则子 agent 并行阶段
/// 思考链内容全程不可见,直到整卡 done 才一次性出现。
///
/// 两态共用：白底 + #EEEEEE 边框 + 点击弹底部抽屉看全文。
class ReasoningRenderer implements MessageContentRenderer {
  const ReasoningRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(BuildContext context, Map<String, dynamic> content, MessageRenderContext rc) {
    final data = content['data'];
    final text = (data is Map ? data['text'] : null) as String? ?? '';

    // 元素级终态标记:false/缺失 → 按卡片流式态决定;true → 已终态,显示真实内容。
    final finished = (data is Map ? data['finished'] : null) as bool? ?? false;
    // 思考耗时(秒):plugin reasoning 元素终态携带(part.time.end - start,对齐 TUI)。
    final duration = (data is Map ? data['duration'] : null) as num?;

    // 流式思考中:text 可能为空(流式占位无文本),但必须渲染「正在思考...」流式卡,
    // 否则聚合卡首元素(思考块)空白 → 整卡内容空直到思考完成才显示。
    if (rc.isStreaming && !finished) {
      return _StreamingReasoningCard(text: text, isDark: rc.isDark);
    }
    // 非流式 + 空文本:无内容可展示(异常/历史占位),返回空。
    if (text.isEmpty) return const SizedBox.shrink();
    return _StaticReasoningCard(text: text, duration: duration, isDark: rc.isDark);
  }
}

/// 终态卡：✨ Thought + 耗时(可选)+ 真实 text 预览(单行截断)。
/// 对齐 TUI reasoning header:`Thought: {duration}`(如 `Thought: 6.7s`)。
/// duration 来自 reasoning 元素 data.duration(plugin 终态时由 part.time 计算,秒)。
/// 点击展开全文。
class _StaticReasoningCard extends StatelessWidget {
  final String text;
  final num? duration;
  /// 深色模式:抽屉底/标题/markdown 主题适配(浅色路径不变)。
  final bool isDark;
  const _StaticReasoningCard({required this.text, this.duration, this.isDark = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showDetail(context, text, isDark: isDark),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            IconFont.icon(IconFont.deepThink, size: 15, color: const Color(0xFFD4A017)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _foldedText(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
            ),
            const Text('▸', style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB))),
          ],
        ),
      ),
    );
  }

  String _foldedText() {
    // 折叠态:中文「思考完成」固定文案,耗时可选。
    // 有耗时(终态元素带 duration,毫秒)显示「思考完成 · 22ms / 思考完成 · 1.6s」;
    // 无耗时(兜底路径)只显示「思考完成」。不再展示全文首行(与 TUI 折叠一致,
    // 布局不随思考内容跳动)。
    if (duration is num && duration! > 0) {
      return '思考完成 · ${formatDurationMs(duration!.toInt())}';
    }
    return '思考完成';
  }
}

/// 流式卡:✨ 闪烁动画 + 真实思考文本(text 非空时显示;空文本显示「正在思考...」)。
///
/// 闪烁:opacity 沿 sin(2πt) 在 0.25 ↔ 1.0 之间平滑往返,周期 1800ms。
class _StreamingReasoningCard extends StatefulWidget {
  final String text;
  /// 深色模式:抽屉底/标题/markdown 主题适配(浅色路径不变)。
  final bool isDark;
  const _StreamingReasoningCard({required this.text, this.isDark = false});

  @override
  State<_StreamingReasoningCard> createState() => _StreamingReasoningCardState();
}

class _StreamingReasoningCardState extends State<_StreamingReasoningCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showDetail(context, widget.text, isDark: widget.isDark),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            // 闪烁:opacity 沿 sin(2πt) 在 0.25 ↔ 1.0 平滑往返。
            // SizedBox 固定尺寸外壳必要:终态切换(本 Stateful → _StaticReasoningCard)
            // 时 element 重建,若 RenderOpacity 直接作为 Row 子节点会引发 SliverList
            // 位置错位(实测:思考完成后卡片跑到下一条消息下方)。
            // SizedBox(RenderConstrainedBox) 把动画 layer 变化隔离在子树内,
            // 不波及 Row 的 child list。
            SizedBox(
              width: 24,
              height: 24,
              child: Center(
                child: AnimatedBuilder(
                  animation: _ctrl,
                  builder: (_, _) {
                    final t = _ctrl.value;
                    final opacity = 0.25 + 0.75 * (math.sin(math.pi * 2 * t) * 0.5 + 0.5);
                    return Opacity(
                      opacity: opacity,
                      child: IconFont.icon(IconFont.deepThink, size: 15, color: const Color(0xFF5B8BF7)),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                // 增量思考(text 非空,post_api_request 每轮更新)显示真实内容;
                // 空文本(建卡占位瞬时态)显示「正在思考...」。单行截断 + 抽屉看全文。
                widget.text.isNotEmpty ? widget.text : '正在思考...',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, color: Color(0xFF999999)),
              ),
            ),
            const Text('▸', style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB))),
          ],
        ),
      ),
    );
  }
}

void _showDetail(BuildContext context, String text, {bool isDark = false}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    // 抽屉深色底对齐 showDetailSheet 体系(1E1F24),浅色白底不变。
    backgroundColor: isDark ? const Color(0xFF1E1F24) : Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36, height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              decoration: BoxDecoration(color: isDark ? const Color(0xFF3A3B42) : const Color(0xFFDDDDDD), borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                IconFont.icon(IconFont.deepThink, size: 18, color: const Color(0xFFD4A017)),
                const SizedBox(width: 6),
                Text('思考', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333))),
              ]),
            ),
            Divider(height: 1, color: isDark ? const Color(0xFF2E2F36) : const Color(0xFFEEEEEE)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: MarkdownView(
                  data: text,
                  config: markdownStyle(isDark: isDark, isMe: false, context: ctx),
                  inlineSyntaxes: [LatexSyntax()],
                  generators: _markdownGenerators,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
