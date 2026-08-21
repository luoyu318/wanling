import 'package:flutter/material.dart';

import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/quote.dart';
import 'package:wanling_core/rendering/footer_status_bar.dart'
    show aggregatePhaseText;
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/rendering/tool_group_renderer.dart'
    show groupAggregateElements, SingleElementSlot, ToolGroupSlot;
import 'desktop_permission_card_renderer.dart';
import 'desktop_reasoning_renderer.dart';
import 'desktop_tool_group_renderer.dart';
import 'package:wanling_core/utils/duration_format.dart';
import 'package:wanling_core/widgets/chat/shimmer_text.dart';

/// 桌面版聚合卡渲染器:分叉自 core aggregate_card_renderer(desktop 启动
/// 时在 registerBuiltinRenderers 后覆盖注册),数据解析/元素分派/子渲染
/// 与 core 版一致,仅外壳不同——透明底、无边框、无阴影,与聊天背景融合
/// (桌面二级卡片再叠白卡会显重)。
class DesktopAggregateCardRenderer implements MessageContentRenderer {
  const DesktopAggregateCardRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'] as Map<String, dynamic>? ?? const {};
    final state = data['state'] as String? ?? 'generating';
    final generating = state != 'done';
    final elements =
        (data['elements'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    // 分组:连续 tool_card 折叠合并(纯渲染层),task/交互卡平铺
    final slots = groupAggregateElements(elements);

    return Container(
      // 桌面外壳:透明底、无边框、无阴影,与聊天背景融合。
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶栏去除后顶部留白:首元素自带上边距 4,补 6 让卡片顶部视觉不挤
          const SizedBox(height: 6),
          // 引用行:聚合卡 data.quote(server 富化引用锚点)顶部展示「| 回复 xx：内容」
          if (data['quote'] is Map<String, dynamic>)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: _QuoteLine(
                quote: Quote.fromJson(data['quote'] as Map<String, dynamic>),
                isDark: rc.isDark,
              ),
            ),
          for (final slot in slots)
            switch (slot) {
              ToolGroupSlot(:final cards) => Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
                // 桌面版折叠组:hover 前导 icon 切换展开指示,无尾部箭头。
                child: DesktopToolGroupCard(cards: cards, rc: rc),
              ),
              SingleElementSlot(:final element) =>
                // finished footer 元素由底部状态条代替渲染(不重复走 step_finish)
                !_isFinishedFooter(element)
                    ? _buildElement(
                        context,
                        element,
                        rc,
                        generating: generating,
                      )
                    : const SizedBox.shrink(),
            },
          // footer 状态条:桌面版自绘轻量行(无底色/无分隔线,与透明外壳
          // 融合;core FooterStatusBar 灰底通栏是贴白卡设计,透明卡上突兀)。
          if (generating)
            _DesktopFooterBar(generating: true, elements: elements)
          else if (_hasFinishedFooter(elements))
            _DesktopFooterBar(
              generating: false,
              elements: elements,
              footerData: _finishedFooterData(elements),
            ),
        ],
      ),
    );
  }

  Widget _buildElement(
    BuildContext context,
    Map<String, dynamic> element,
    MessageRenderContext rc, {
    required bool generating,
  }) {
    final type = element['type'] as String? ?? '';
    final elementId = element['element_id'] as String? ?? '';
    final data = element['data'] as Map<String, dynamic>? ?? const {};

    // 子元素渲染上下文：messageId 用 element_id（保证卡片内各元素唯一，
    // 避免 markdown 流式 StreamingText 的 ValueKey(rc.messageId) 兄弟节点冲突）；
    // rootMessageId 用外层 rc.messageId（= 聚合卡真实消息 id）：task 元素跳转
    // 子 Agent 详情页时需用 root_msg_id = 聚合卡真实 id 拉子树，element_id 查不到；
    // isStreaming 派生自卡片 state（generating 期间元素仍在流式输出），但交互元素
    // （question_card / permission_card）固定 false：只读字段本身不消费该值，
    // 且交互卡不应受卡片流式态影响（generating 期间也保持可点击终态语义）。
    final interactive = type == 'question_card' || type == 'permission_card';
    final elementRc = MessageRenderContext(
      isMe: rc.isMe,
      baseUrl: rc.baseUrl,
      token: rc.token,
      isDark: rc.isDark,
      convId: rc.convId,
      messageId: elementId,
      rootMessageId: rc.messageId,
      conversationMessages: rc.conversationMessages,
      openGallery: rc.openGallery,
      onFileTap: rc.onFileTap,
      fileDownloadSnapshots: rc.fileDownloadSnapshots,
      // 折叠展开滚动补偿:透传给聚合卡内可折叠元素(todowrite/权限卡终态等),
      // 让它们展开/收起时同帧上报 ChatPage jumpTo 补偿(history 反向列表)。
      onToolGroupToggle: rc.onToolGroupToggle,
      isHistorySliver: rc.isHistorySliver,
      isStreaming: interactive ? false : generating,
    );

    final elementContent = <String, dynamic>{'msg_type': type, 'data': data};

    final Widget child = switch (type) {
      // 桌面版思考块:hover 前导 icon 切换,点击卡内原地展开(core registry 版弹抽屉)。
      'reasoning' => DesktopReasoningCard(
        text: ((data['text'] as String?) ?? ''),
        duration: data['duration'] as num?,
        rc: elementRc,
      ),
      'tool_card' => ContentRendererRegistry.render(
        MsgType.toolCard,
        elementContent,
        context,
        elementRc,
      ),
      'markdown' => ContentRendererRegistry.render(
        MsgType.markdown,
        elementContent,
        context,
        elementRc,
      ),
      'compact_divider' => _buildCompactDivider(elementRc),
      'footer' => ContentRendererRegistry.render(
        MsgType.stepFinish,
        elementContent,
        context,
        elementRc,
      ),
      'question_card' => ContentRendererRegistry.render(
        MsgType.questionCard,
        elementContent,
        context,
        elementRc,
      ),
      'permission_card' => const DesktopPermissionCardRenderer()
          .build(context, elementContent, elementRc),
      _ => const SizedBox.shrink(),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: child,
    );
  }

  /// 压缩分隔线:元素间视觉分段(自绘细线,不引入 Divider 默认上下间距)。
  /// 深色模式切深灰分隔色,浅色保持 #F5F5F5。
  Widget _buildCompactDivider(MessageRenderContext rc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        height: 1,
        color: rc.isDark ? const Color(0xFF2E2F36) : const Color(0xFFF5F5F5),
      ),
    );
  }

  /// 是否存在 finished==true 的 footer 元素(回合结束信号)。
  bool _hasFinishedFooter(List<Map<String, dynamic>> elements) {
    for (final e in elements) {
      if (e['type'] == 'footer') {
        final d = e['data'] as Map?;
        if (d?['finished'] == true) return true;
      }
    }
    return false;
  }

  /// 单个元素是否为 finished footer(由提示条代替渲染,不再走 step_finish)。
  bool _isFinishedFooter(Map<String, dynamic> element) {
    if (element['type'] != 'footer') return false;
    final d = element['data'] as Map?;
    return d?['finished'] == true;
  }

  /// 取 finished footer 的 data(供提示条读 mode/model/duration/tokens)。
  Map<String, dynamic> _finishedFooterData(
    List<Map<String, dynamic>> elements,
  ) {
    for (final e in elements) {
      if (e['type'] == 'footer') {
        final d = e['data'] as Map?;
        if (d?['finished'] == true) {
          return Map<String, dynamic>.from(d as Map);
        }
      }
    }
    return const {};
  }
}

/// 聚合卡内引用行：`| 引用线，无背景色`（区别于独立消息的浅紫底引用块）。
/// 示例：`| 回复 洛羽：查到了吗？`
class _QuoteLine extends StatelessWidget {
  final Quote quote;

  /// 深色模式(桌面端):引用文字亮一档(#888 → #999);浅色(app 壳)不变。
  final bool isDark;
  const _QuoteLine({required this.quote, this.isDark = false});

  @override
  Widget build(BuildContext context) {
    final name = quote.senderName.isNotEmpty
        ? quote.senderName
        : quote.senderId;
    // 边框竖线：IntrinsicHeight 让竖线拉伸到内容高度（居中于引用内容），
    // 2px 主题色左竖线 + 无背景色，对齐「| 引用线」样式。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            width: 2,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF597BFF),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? const Color(0xFF999999)
                      : const Color(0xFF888888),
                ),
                children: [
                  const TextSpan(text: '回复 '),
                  TextSpan(
                    text: name,
                    style: const TextStyle(
                      color: Color(0xFF597BFF),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  TextSpan(text: '：${quote.preview}'),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面版 footer 行:透明外壳内的轻量元信息,无底色/无分隔线。
/// - generating:阶段词闪烁(ShimmerText,文案复用 core aggregatePhaseText);
/// - done/stopped:模式 + 时长(左),模型 + tokens(右),全部低对比灰小字,
///   视觉上与正文自然分隔(靠留白而非通栏)。
class _DesktopFooterBar extends StatelessWidget {
  final bool generating;
  final List<Map<String, dynamic>> elements;
  final Map<String, dynamic> footerData;

  const _DesktopFooterBar({
    required this.generating,
    required this.elements,
    this.footerData = const {},
  });

  @override
  Widget build(BuildContext context) {
    if (generating) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: ShimmerText(
          text: aggregatePhaseText(elements),
          baseColor: const Color(0xFF07C160),
          style: const TextStyle(fontSize: 11),
        ),
      );
    }
    // 主动停止态:仅「已停止」灰字。
    if (footerData['stopped'] == true) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: Text(
          '已停止',
          style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
        ),
      );
    }
    final mode = (footerData['mode'] as String?) ?? '';
    final model = (footerData['model'] as String?) ?? '';
    final duration = footerData['duration'];
    final durationText = duration is num && duration > 0
        ? formatDurationMs(duration.toInt())
        : '';
    final tokens = footerData['tokens'];
    final total = tokens is Map ? tokens['total'] : null;
    final tokensText = total is num && total > 0
        ? '${(total / 1000).toStringAsFixed(1)}k'
        : '';
    // 四要素全空(历史 footer 无快照):不渲染空行。
    if (mode.isEmpty &&
        durationText.isEmpty &&
        model.isEmpty &&
        tokensText.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Row(
        children: [
          if (mode.isNotEmpty)
            const Text(
              '模式',
              style: TextStyle(fontSize: 10, color: Color(0xFF999999)),
            ),
          if (mode.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(
              mode,
              style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
            ),
          ],
          if (durationText.isNotEmpty) ...[
            if (mode.isNotEmpty) const SizedBox(width: 10),
            Text(
              durationText,
              style: const TextStyle(fontSize: 11, color: Color(0xFF07C160)),
            ),
          ],
          const Spacer(),
          if (model.isNotEmpty)
            Text(
              model,
              style: const TextStyle(fontSize: 11, color: Color(0xFF5B8BF7)),
            ),
          if (tokensText.isNotEmpty) ...[
            if (model.isNotEmpty) const SizedBox(width: 10),
            Text(
              'tokens $tokensText',
              style: const TextStyle(fontSize: 11, color: Color(0xFFFA8C16)),
            ),
          ],
        ],
      ),
    );
  }
}
