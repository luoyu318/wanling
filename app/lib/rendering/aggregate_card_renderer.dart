import 'package:flutter/material.dart';

import '../models/msg_type.dart';
import 'message_content_renderer.dart';

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

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE8E8E8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(generating: generating),
          for (final e in elements)
            _buildElement(context, e, rc, generating: generating),
        ],
      ),
    );
  }

  /// 顶部状态条：generating → 绿色「回复中」；done → 深灰「完成」。
  Widget _buildHeader({required bool generating}) {
    final color = generating
        ? const Color(0xFF07C160)
        : const Color(0xFF666666);
    return Container(
      color: const Color(0xFFF7F7F7),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            generating ? '回复中' : '完成',
            style: TextStyle(fontSize: 12, color: color),
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
      conversationMessages: rc.conversationMessages,
      openGallery: rc.openGallery,
      onFileTap: rc.onFileTap,
      fileDownloadSnapshots: rc.fileDownloadSnapshots,
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
      'compact_divider' => _buildCompactDivider(),
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

  /// 压缩分隔线：元素间视觉分段（自绘细线，不引入 Divider 默认上下间距）。
  Widget _buildCompactDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        height: 1,
        color: const Color(0xFFEEEEEE),
      ),
    );
  }
}
