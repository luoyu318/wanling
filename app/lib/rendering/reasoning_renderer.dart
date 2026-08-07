import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../widgets/markdown_block_spacing.dart';
import '../widgets/markdown_config.dart';
import '../widgets/markdown_latex.dart';
import '../widgets/markdown_strong.dart';
import '../widgets/markdown_view.dart';
import '../utils/duration_format.dart';
import 'message_content_renderer.dart';

/// MarkdownView 共用的 generators（与 builtin_renderers.dart 一致，改时同步）。
final List<SpanNodeGeneratorWithTag> _markdownGenerators = [
  latexGenerator,
  strongGenerator,
  hrSpacingGenerator,
  ...headingSpacingGenerators(),
];

/// AI 思考链渲染器：读 [MessageRenderContext.isStreaming] 分发到两态子 widget。
/// - 流式态(isStreaming=true 且 data.finished != true)：✨ 闪烁动画 + 「正在思考...」固定文案
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
    if (text.isEmpty) return const SizedBox.shrink();

    // 元素级终态标记:false/缺失 → 按卡片流式态决定;true → 已终态,显示真实内容。
    final finished = (data is Map ? data['finished'] : null) as bool? ?? false;
    // 思考耗时(秒):plugin reasoning 元素终态携带(part.time.end - start,对齐 TUI)。
    final duration = (data is Map ? data['duration'] : null) as num?;
    if (rc.isStreaming && !finished) {
      return _StreamingReasoningCard(text: text);
    }
    return _StaticReasoningCard(text: text, duration: duration);
  }
}

/// 终态卡：✨ Thought + 耗时(可选)+ 真实 text 预览(单行截断)。
/// 对齐 TUI reasoning header:`Thought: {duration}`(如 `Thought: 6.7s`)。
/// duration 来自 reasoning 元素 data.duration(plugin 终态时由 part.time 计算,秒)。
/// 点击展开全文。
class _StaticReasoningCard extends StatelessWidget {
  final String text;
  final num? duration;
  const _StaticReasoningCard({required this.text, this.duration});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showDetail(context, text),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEF), // 浅黄底(思考态)
          borderRadius: BorderRadius.circular(4),
          border: const Border(
            left: BorderSide(color: Color(0xFFFFC940), width: 2), // 琥珀左条
          ),
        ),
        child: Row(
          children: [
            const Opacity(
              opacity: 0.6,
              child: Text('✨ ', style: TextStyle(fontSize: 14)),
            ),
            Expanded(
              child: Text(
                _foldedText(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFF8A6D00)),
              ),
            ),
            const Text('▸', style: TextStyle(fontSize: 11, color: Color(0xFF888888))),
          ],
        ),
      ),
    );
  }

  String _foldedText() {
    // 折叠态对齐 TUI:`Thought` 固定文案,耗时可选。
    // 有耗时(终态元素带 duration,毫秒)显示「Thought: 22ms / Thought: 1.6s」;
    // 无耗时(兜底路径)只显示「Thought」。不再展示全文首行(与 TUI 折叠一致,
    // 布局不随思考内容跳动)。
    if (duration is num && duration! > 0) {
      return 'Thought: ${formatDurationMs(duration!.toInt())}';
    }
    return 'Thought';
  }
}

/// 流式卡:✨ 闪烁动画 + 「正在思考...」固定文案。
///
/// 闪烁:opacity 沿 sin(2πt) 在 0.25 ↔ 1.0 之间平滑往返,周期 1800ms。
class _StreamingReasoningCard extends StatefulWidget {
  final String text;
  const _StreamingReasoningCard({required this.text});

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
      onTap: () => _showDetail(context, widget.text),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFBEF), // 浅黄底(思考态)
          borderRadius: BorderRadius.circular(4),
          border: const Border(
            left: BorderSide(color: Color(0xFFFFC940), width: 2), // 琥珀左条
          ),
        ),
        child: Row(
          children: [
            // ✨ 闪烁:opacity 沿 sin(2πt) 在 0.25 ↔ 1.0 平滑往返。
            // SizedBox 固定尺寸外壳必要:终态切换(本 Stateful → _StaticReasoningCard)
            // 时 element 重建,若 RenderOpacity 直接作为 Row 子节点会引发 SliverList
            // 位置错位(实测:思考完成后卡片跑到下一条消息下方)。
            // SizedBox(RenderConstrainedBox) 把动画 layer 变化隔离在子树内,
            // 不波及 Row 的 child list,与光环版结构一致。
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
                      child: const Text('✨ ', style: TextStyle(fontSize: 14)),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Expanded(
              child: Text(
                '正在思考...',
                style: TextStyle(fontSize: 12, color: Color(0xFF8A6D00)),
              ),
            ),
            const Text('▸', style: TextStyle(fontSize: 11, color: Color(0xFF8A6D00))),
          ],
        ),
      ),
    );
  }
}

void _showDetail(BuildContext context, String text) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
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
              decoration: BoxDecoration(color: const Color(0xFFDDDDDD), borderRadius: BorderRadius.circular(2)),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                Text('💭 ', style: TextStyle(fontSize: 16)),
                Text('思考链', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
              ]),
            ),
            const Divider(height: 1, color: Color(0xFFEEEEEE)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: MarkdownView(
                  data: text,
                  config: markdownStyle(isDark: false, isMe: false, context: ctx),
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
