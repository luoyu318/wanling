import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/conversation.dart' show Conversation;
import '../../models/message.dart';
import '../../models/msg_type.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_state.dart' show ChatState;
import '../../providers/settings_provider.dart';
import '../../utils/chat/gallery_opener.dart' show openGallery;
import 'compact_divider.dart';
import 'enter_expand.dart';
import 'message_bubble.dart' show formatTimestamp;
import 'message_row.dart' show MessageRow;
import 'unread_separator.dart';
import 'file_download_controller.dart';
import 'jump_controller.dart';
import 'message_menu_controller.dart' show MessageMenuController;
import 'multi_select_controller.dart';
import 'recalled_bubble.dart' show RecalledBubble;

/// itemBuilder 的依赖打包(chat_page build 方法中的局部变量 + 控制器)。
///
/// [_extraItems] 不在此处:它已烘焙进 itemCount(messages.length + _extraItems),
/// itemBuilder 仅靠 [isTyping] 调整索引偏移(typing bubble 占 index 0)。
@immutable
class ChatMessageItemBuildContext {
  final ChatState chatState;
  final String currentUserId;
  final Conversation? convForStatus;
  final Map<String, GlobalKey> bubbleKeys;
  final bool isTyping;
  final bool isAgentBubble;
  final MessageMenuController menuController;
  final MultiSelectController multiSelectController;
  final FileDownloadController fileController;
  final JumpController jumpController;
  final WidgetRef ref;

  /// 聚合卡工具折叠组展开/收起回调(ChatPage 滚动补偿用)。
  /// null = 不启用补偿(测试/非聊天页)。
  final void Function(GlobalKey key, bool expanded, double topDelta,
      bool isHistory)? onToolGroupToggle;

  /// 当前消息所属 sliver:true = history(反向列表,展开需滚动补偿)/
  /// false = live(正向,展开自然向下,无需补偿)。
  /// 由 ChatPage 在 history/live 两个 sliver 的 buildMessage 分别传入。
  final bool isHistorySliver;

  const ChatMessageItemBuildContext({
    required this.chatState,
    required this.currentUserId,
    required this.convForStatus,
    required this.bubbleKeys,
    required this.isTyping,
    required this.isAgentBubble,
    required this.menuController,
    required this.multiSelectController,
    required this.fileController,
    required this.jumpController,
    required this.ref,
    this.onToolGroupToggle,
    this.isHistorySliver = false,
  });

  /// 复制并覆盖 sliver 归属(history/live 两个 builder 共用 base ctx)。
  ChatMessageItemBuildContext copyWith({bool? isHistorySliver}) {
    return ChatMessageItemBuildContext(
      chatState: chatState,
      currentUserId: currentUserId,
      convForStatus: convForStatus,
      bubbleKeys: bubbleKeys,
      isTyping: isTyping,
      isAgentBubble: isAgentBubble,
      menuController: menuController,
      multiSelectController: multiSelectController,
      fileController: fileController,
      jumpController: jumpController,
      ref: ref,
      onToolGroupToggle: onToolGroupToggle,
      isHistorySliver: isHistorySliver ?? this.isHistorySliver,
    );
  }
}

/// ChatPage 双 sliver 的单条消息构造器。
///
/// 处理(单条消息维度):
/// - 时间戳(首条或距下条 ≥5min)
/// - 未读分隔线
/// - 撤回消息(RecalledBubble)
/// - 正常消息(MessageRow + 引用块高亮)
///
/// 不含 typing bubble / loadMore indicator(双 sliver 架构中由调用方 sliver 单独组装)。
class ChatMessageItemBuilder {
  /// 按单条消息构造 widget(双 sliver 用)。
  ///
  /// 时间戳分组由调用方通过 [olderNeighbor] 传入(视觉上更老的相邻消息):
  /// null 表示当前是最老的一条(显示时间戳)。
  static Widget buildMessage(
    BuildContext context,
    ChatMessage message,
    ChatMessageItemBuildContext ctx, {
    ChatMessage? olderNeighbor,
    bool animateEntry = false,
  }) {
    final chatState = ctx.chatState;
    final currentUserId = ctx.currentUserId;
    final convForStatus = ctx.convForStatus;
    // 子 agent 审批卡(permission_card/question_card,parent_msg_id 非空)不在扁平
    // 聊天流里单独渲染:pending 卡贴对应 task 卡片下方(⚡ 缩略条),终态卡不展示。
    // 不限 status 兜底:终态卡若因时序窗口留在列表(如双 PATCH 时序),也不漏出完整行。
    if (message.isChildApprovalCard) {
      return const SizedBox.shrink();
    }
    // compact_divider(对话压缩分割线):不走 MessageRow,直接渲染 CompactDivider。
    // 无头像/昵称/时间戳/未读分隔线,仅一条横线 + 状态文案。
    if (MsgTypeX.fromString(message.content['msg_type'] as String?) ==
        MsgType.compactDivider) {
      final phase =
          (message.content['data'] as Map<String, dynamic>?)?['phase']
                  as String? ??
              'running';
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: CompactDivider(phase: phase),
      );
    }
    final showTime = olderNeighbor == null ||
        message.createdAt
                .difference(olderNeighbor.createdAt)
                .inMinutes
                .abs() >=
            5;

    // 判断是否在此消息前显示未读分隔线
    final showSeparatorBefore =
        chatState.showUnreadSeparator &&
        chatState.firstUnreadMessageId == message.id;

    // 每条消息一个 GlobalKey,用于拿 RenderObject 算菜单定位/出屏判定。
    final bubbleKey = ctx.bubbleKeys.putIfAbsent(
      message.id,
      () => GlobalKey(),
    );
    // 撤回占位:不显示头像/昵称,直接用 RecalledBubble。
    // 文案优先级:isMe →「你撤回了一条消息」(单聊/群聊一致);
    // 否则 isGroup + 有 senderName →「${name} 撤回了一条消息」;
    // 否则 →「对方撤回了一条消息」。
    // senderName 来源:实时撤回 payload 带 sender_name(server recall scope),
    // 重进拉历史 server SanitizeForClient 也保留 last_message_sender_name,
    // 两路一致(server conversation_repo + message sanitize 均补该字段)。
    final isMe = message.senderId == currentUserId;
    final isTuiUser =
        MsgTypeX.fromString(
          message.content['msg_type'] as String?,
        ) ==
        MsgType.tuiUser;
    final effectiveIsMe = isMe || isTuiUser;
    // 会话类型决定头像/昵称渲染规则:
    // - dm_user_agent / agent_session:不显示头像/昵称,不占位
    //   (agent 信息在 AppBar 已显示,消息行不重复)
    // - dm_user_user:只显示头像(无昵称)
    // - group_*:头像 + 昵称都显示
    // 每条消息都显示头像/昵称(取消连续消息分组,视觉更整齐)。
    // convForStatus 优先(conversationProvider 含完整信息)；
    // agent_session 被 ListForUser 排除，fallback 用 chatState.convType。
    final conv = convForStatus;
    final effectiveType = conv?.type ?? chatState.convType;
    final isGroup = conv?.isGroup ??
        (effectiveType == 'group_user' ||
            effectiveType == 'group_mixed' ||
            effectiveType == 'agent_session');
    final isUserAgentDM = conv?.isUserAgentDM ??
        (effectiveType == 'dm_user_agent');
    final isAgentSession = conv?.isAgentSession ??
        (effectiveType == 'agent_session');
    final slimRow = isUserAgentDM || isAgentSession;
    final showAvatar = !slimRow;
    final showNickname = isGroup && !isAgentSession;
    final reserveAvatarSpace = !slimRow;

    final Widget row;
    if (message.isRecalled) {
      row = RecalledBubble(
        isMe: isMe,
        isGroup: isGroup && !isAgentSession,
        senderName: message.senderName,
      );
    } else {
      // 查本地缓存判断被引用消息是否撤回:
      //   - 本地能查到 → 用本地 isRecalled 最新状态(撤回 dispatch
      //     可能在引用消息之后到达,本地状态比 server snapshot 更新)
      //   - 本地查不到(跨页引用 / 历史窗口外)→ 不强制 revoked,
      //     信任 server quote.preview snapshot(server enrichQuote
      //     在发送时已检查 quoted.DeletedAt.Valid,撤回的 preview
      //     会被改成「[消息已撤回]」)。原降级逻辑「idx<0→revoked=true」
      //     会把所有跨页引用误判为已撤回。
      bool isQuoteRevoked = false;
      // displayMessages 全局排序有 O(n log n) 成本,buildMessage 是热路径(每条可见消息一次),
      // 此处缓存一次复用给 quote 查找 / conversationMessages / openGallery。
      final display = chatState.displayMessages;
      if (message.quote != null) {
        final idx = display.indexWhere(
          (m) => m.id == message.quote!.messageId,
        );
        if (idx >= 0) {
          isQuoteRevoked = display[idx].isRecalled;
        }
      }
      row = MessageRow(
        key: bubbleKey,
        message: message,
        isMe: effectiveIsMe,
        isGroup: isGroup,
        showAvatar: showAvatar,
        showNickname: showNickname,
        reserveAvatarSpace: reserveAvatarSpace,
        baseUrl: ctx.ref.read(settingsProvider),
        token: ctx.ref.read(authProvider).token ?? '',
        conversationMessages: display,
        openGallery: (fileId) => openGallery(
          context: context,
          ref: ctx.ref,
          fileId: fileId,
          messages: display,
        ),
        // 文件点击 + 下载状态注入（仅 file 类型消息在 rc 层查 map）。
        // 多选模式下 FileCard 不响应点击（外层 AbsorbPointer），
        // 但 onTap 仍可保留无副作用。
        onFileTap: ctx.fileController.onFileTap,
        fileDownloadSnapshots:
            ctx.fileController.buildSnapshots(),
        selectionMode: ctx.multiSelectController.isSelectionMode,
        selected: ctx.multiSelectController.isSelected(message.id),
        onToolGroupToggle: ctx.onToolGroupToggle,
        isHistorySliver: ctx.isHistorySliver,
        onLongPressStart: ctx.multiSelectController.isSelectionMode
            ? null
            : (details) => ctx.menuController.showMessageMenu(message),
        onTapSelect: ctx.multiSelectController.isSelectionMode
            ? () => ctx.multiSelectController.toggleSelect(message.id)
            : null,
        onFailedTap: () => ctx.menuController.showFailedMenu(message),
        // 引用块点击 → 跳转被引用消息(Task 16 实现真跳转,本 task 占位)
        onJumpToMessage: (messageId) =>
            ctx.jumpController.jumpToMessage(messageId),
        isQuoteRevoked: isQuoteRevoked,
      );
    }

    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showTime)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                vertical: 8,
              ),
              child: Text(
                formatTimestamp(message.createdAt),
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF999999),
                ),
              ),
            ),
          ),
        if (showSeparatorBefore)
          const UnreadSeparator(),
        // 引用跳转高亮:1s flash 背景。AnimatedContainer
        // 让背景出现/消失有渐变,不至于突兀。
        if (ctx.jumpController.highlightedMessageId == message.id)
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: const BoxDecoration(
              color: Color(0x33FFE082),
            ),
            child: row,
          )
        else
          row,
      ],
    );

    // 实时新消息入场展开动画:仅 live sliver 的卡片/审批卡与流式思考消息首次出现
    // 时从 0 高度向下展开。历史消息加载(animateEntry=false)与 reasoning 终态替换
    // (isStreaming=false,element 已重建)不播,避免每条历史卡片滑入都展开/终态重播闪烁。
    final msgType = MsgTypeX.fromString(message.content['msg_type'] as String?);
    final isCardLike = msgType == MsgType.card || msgType == MsgType.toolCard;
    final isStreamingReasoning =
        msgType == MsgType.reasoning && message.isStreaming;
    if (animateEntry && (isCardLike || isStreamingReasoning)) {
      return EnterExpand(animate: true, child: column);
    }
    return column;
  }
}
