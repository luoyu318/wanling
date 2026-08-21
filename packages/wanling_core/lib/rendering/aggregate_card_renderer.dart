import 'package:flutter/material.dart';

import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/quote.dart';
import 'footer_status_bar.dart';
import 'message_content_renderer.dart';
import 'tool_group_renderer.dart';

/// 聚合卡片渲染器：把一次问答的全部时序内容（思考 / 工具 / 正文 / 分隔 / 信息行）
/// 渲染成一张卡片。
///
/// content.data 结构（与 plugin aggregate_card.ts / server 透传对齐）：
/// - state: 'generating' | 'done'（回合是否仍在生成）
/// - elements: [{type, element_id, data}] 按时序排列
///
/// 元素分派：reasoning / tool_card / markdown / footer 复用 [ContentRendererRegistry]
/// 现有 renderer（元素 data 结构与对应 renderer 的 content.data 对齐，
/// 见 aggregate_card.ts 的 AggregateElement.data）；compact_divider 无现有 renderer，
/// 本地渲染压缩分隔线。
///
/// 卡片外壳：白底圆角 + 顶部状态条。state=generating 顶部显示「回复中」，
/// done 显示「完成」。元素流式态由卡片 state 派生（generating 期间元素仍在输出），
/// 透传给子 renderer（markdown 走 StreamingText、reasoning 走思考中动画）。
class AggregateCardRenderer implements MessageContentRenderer {
  const AggregateCardRenderer();

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
    final elements = (data['elements'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];

    // 分卡序列圆角:data.segment 三态标记(first/middle/last)决定四角。
    // first→下边平(其下还有续卡);middle→上下平;last→上边平(其上还有前卡);
    // 无标记=未分卡单卡,保持现状(左上直角对齐头像,其余三角圆角)。
    final segment = data['segment'] as String?;
    final radius = BorderRadius.only(
      topLeft: Radius.zero, // 左上恒直角(对齐头像起始)
      topRight: (segment == null || segment == 'first')
          ? const Radius.circular(12)
          : Radius.zero,
      bottomLeft: (segment == null || segment == 'last')
          ? const Radius.circular(12)
          : Radius.zero,
      bottomRight: (segment == null || segment == 'last')
          ? const Radius.circular(12)
          : Radius.zero,
    );

    // 分组:连续 tool_card 折叠合并(纯渲染层),task/交互卡平铺
    final slots = groupAggregateElements(elements);

    // 分段序列内卡间距:first/middle 下面还有续卡 → 缝 4px;
    // 末卡(下面无续卡)/单卡保持 8px 常规间距。
    final bottomMargin =
        (segment == 'first' || segment == 'middle') ? 4.0 : 8.0;

    return Container(
      margin: EdgeInsets.only(bottom: bottomMargin),
      // 左上角直角(对齐头像起始),其余三角 12px 圆角;无边框,阴影浮起(0x1A = 10% 黑)
      // 分卡序列按 data.segment 调整四角(相邻接触处直角,首末保留圆角)。
      decoration: BoxDecoration(
        // 深色模式(桌面端)卡片底色切深灰,浅色(app 壳)保持白底
        color: rc.isDark ? const Color(0xFF26272D) : Colors.white,
        borderRadius: radius,
        // 阴影参数恒定,radius 动态故 BoxDecoration 本身不能 const,阴影子项可 const
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
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
                    child: ToolGroupCard(cards: cards, rc: rc),
                  ),
                SingleElementSlot(:final element) =>
                  // finished footer 元素由底部状态条代替渲染(不重复走 step_finish)
                  !_isFinishedFooter(element)
                      ? _buildElement(context, element, rc, generating: generating)
                      : const SizedBox.shrink(),
              },
            // footer 状态条:generating→动态阶段词;done+finished footer→静态信息条
            if (generating)
              FooterStatusBar(
                generating: true,
                elements: elements,
                footerData: const {},
                isDark: rc.isDark,
              )
            else if (_hasFinishedFooter(elements))
              FooterStatusBar(
                generating: false,
                elements: elements,
                footerData: _finishedFooterData(elements),
                isDark: rc.isDark,
              ),
          ],
        ),
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
    final interactive =
        type == 'question_card' || type == 'permission_card';
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
      'reasoning' => ContentRendererRegistry.render(
          MsgType.reasoning, elementContent, context, elementRc),
      'tool_card' => ContentRendererRegistry.render(
          MsgType.toolCard, elementContent, context, elementRc),
      'markdown' => ContentRendererRegistry.render(
          MsgType.markdown, elementContent, context, elementRc),
      'compact_divider' => _buildCompactDivider(elementRc),
      'footer' => ContentRendererRegistry.render(
          MsgType.stepFinish, elementContent, context, elementRc),
      'question_card' => ContentRendererRegistry.render(
          MsgType.questionCard, elementContent, context, elementRc),
      'permission_card' => ContentRendererRegistry.render(
          MsgType.permissionCard, elementContent, context, elementRc),
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
      List<Map<String, dynamic>> elements) {
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
    final name = quote.senderName.isNotEmpty ? quote.senderName : quote.senderId;
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
