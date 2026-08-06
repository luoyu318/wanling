import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/message.dart';
import '../../providers/agent_provider.dart';
import '../../providers/auth_provider.dart';
import '../../rendering/message_content_renderer.dart' show FileDownloadSnapshot;
import '../avatar.dart';
import 'message_bubble.dart';
import 'message_quote_block.dart';

/// 单条消息行:组合 [Avatar] + 昵称(群聊接收方)+ [MessageBubble] + 状态指示器。
///
/// **职责分离**:本 widget 负责「整行的左右布局 + 头像/昵称/状态位置」;
/// [MessageBubble] 只负责「气泡外壳 + 三角 + 内容渲染」,不再关心状态/头像。
///
/// **布局**:
/// - 接收方(not isMe, 非多选):Row([Avatar?, Col([Nickname?, Bubble])]) 靠左
/// - 发送方(isMe, 非多选):Row([StatusIcon?, Bubble, Avatar?]) 靠右
/// - 多选模式:不渲染头像/昵称(勾选框由 MessageBubble 内部处理)
///
/// **连续消息分组**:由调用方(chat_page)计算 [showAvatar] / [showNickname]:
/// 同一 sender 连续消息只在首条显示头像/昵称,后续消息保留 36px 占位(避免气泡宽度跳变)。
///
/// **昵称空串保护**:server COALESCE 在 user/agent 双方都没设昵称时返空串而非 null,
/// 判断「显示昵称」时用 `?.isNotEmpty ?? false` 而非 `!= null`,避免渲染空 Text。
class MessageRow extends ConsumerWidget {
  final ChatMessage message;
  final bool isMe;

  /// 是否群聊(仅用于调用方表达意图,本 widget 渲染逻辑只看 [showNickname])。
  /// chat_page 在群聊接收方 + 首条消息时同时传 isGroup=true + showNickname=true,
  /// 单聊或群聊发送方传 isGroup + showNickname=false。
  final bool isGroup;
  final bool showAvatar;
  final bool showNickname;
  final String baseUrl;
  final String token;
  final List<ChatMessage> conversationMessages;
  final void Function(String fileId)? openGallery;

  /// 文件卡片点击回调 (fileId, filename, mimeType, fileSize)。透传给 MessageBubble。
  final void Function(String fileId, String filename, String mimeType, int fileSize)? onFileTap;

  /// 文件下载状态快照表 (fileId → snapshot)。透传给 MessageBubble → FileContentRenderer。
  final Map<String, FileDownloadSnapshot>? fileDownloadSnapshots;

  final bool selectionMode;
  final bool selected;
  final void Function(LongPressStartDetails)? onLongPressStart;
  final VoidCallback? onTapSelect;
  final VoidCallback? onFailedTap;

  /// showAvatar=false 时是否仍保留头像宽度的占位(连续消息分组避免气泡宽度跳变)。
  /// dm_user_agent 单聊整场都不显示头像,传 false 不占位(避免气泡被挤)。
  final bool reserveAvatarSpace;

  /// 跳转到被引用消息的回调。Task 16 接入跳转逻辑(滚动 + 高亮)。
  /// 仅在 message.quote != null 时会被调用。
  final void Function(String messageId)? onJumpToMessage;

  /// 被引用消息是否已撤回(本地状态,默认 false)。Task 15 接入本地撤回查询。
  /// true 时引用块 preview 显示「原消息已撤回」。
  final bool isQuoteRevoked;

  const MessageRow({
    super.key,
    required this.message,
    required this.isMe,
    required this.isGroup,
    required this.showAvatar,
    required this.showNickname,
    required this.baseUrl,
    required this.token,
    this.conversationMessages = const [],
    this.openGallery,
    this.onFileTap,
    this.fileDownloadSnapshots,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPressStart,
    this.onTapSelect,
    this.onFailedTap,
    this.reserveAvatarSpace = true,
    this.onJumpToMessage,
    this.isQuoteRevoked = false,
  });

  static const double _avatarSize = 40;
  static const double _avatarScreenMargin = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bubble = MessageBubble(
      message: message,
      isMe: isMe,
      baseUrl: baseUrl,
      token: token,
      conversationMessages: conversationMessages,
      openGallery: openGallery,
      onFileTap: onFileTap,
      fileDownloadSnapshots: fileDownloadSnapshots,
      selectionMode: selectionMode,
      selected: selected,
      onLongPressStart: onLongPressStart,
      onTapSelect: onTapSelect,
      // bubble 自身 outerPadding=zero(所有场景):
      // 行间距/左右 padding 由外层 Padding 控制(包整个 Row)。
      // 这样 status icon 跟 bubble 中心对齐时,跟气泡主体(BubbleWithTail)精确居中,
      // 不被 outerPadding.bottom 推偏。
      outerPadding: EdgeInsets.zero,
    );

    // 多选模式:MessageBubble 内部已渲染勾选框,本 widget 不再叠加头像/昵称/状态
    if (selectionMode) {
      return bubble;
    }

    // 是否真渲染昵称(空串保护:server COALESCE 兜底空串时不画;发送方永不渲染昵称)
    final bool nicknameShown = !isMe &&
        showNickname &&
        (message.senderName?.isNotEmpty ?? false);

    // 自己发的消息强制用本地 currentUser 头像/昵称,绕过 server 数据不一致
    // (server processor.senderAvatarURL 偶发返空,WS echo 覆盖乐观消息时会丢头像 → 字母色块)
    final currentUser = ref.read(authProvider).user;
    // agent 消息 fallback:message.senderName 可能因本地 DB 缓存旧数据为 null,
    // 从 agentByIdProvider 兜底取 agent name。
    final String? agentFallbackName = !isMe &&
            message.senderType == 'agent' &&
            (message.senderName ?? '').isEmpty
        ? ref.read(agentByIdProvider(message.senderId))?.name
        : null;
    final String? agentFallbackAvatar = !isMe &&
            message.senderType == 'agent' &&
            (message.senderAvatarUrl ?? '').isEmpty
        ? ref.read(agentByIdProvider(message.senderId))?.avatarUrl
        : null;
    final String effectiveName = isMe
        ? (currentUser?.displayName ?? '')
        : (message.senderName ?? agentFallbackName ?? '');
    final String? effectiveAvatarUrl =
        isMe ? currentUser?.avatarUrl : (message.senderAvatarUrl ?? agentFallbackAvatar);
    if (effectiveName.isEmpty && !isMe) {
      debugPrint(
        '[debug-avatar] EMPTY senderName for msg id=${message.id} '
        'senderType=${message.senderType} senderId=${message.senderId} '
        'status=${message.status}',
      );
    }

    // 头像 widget(含屏幕边缘间距 + 跟 bubble 顶部对齐):
    // - showAvatar=true:Avatar(40) + 距屏幕边缘 6(接收方 left / 发送方 right)
    //   + top=0(两侧 bubble 外层 padding 都 only(bottom: 8),头像跟 bubble 顶部齐 =
    //     接收方有昵称时跟 nickname 顶部齐,无昵称/发送方跟 bubble 外壳顶部齐)
    // - showAvatar=false + reserveAvatarSpace=true:SizedBox 占位(避免气泡左/右移)
    // - showAvatar=false + reserveAvatarSpace=false:SizedBox.shrink(完全不占位,如 dm_user_agent)
    final Widget avatarSlot;
    if (showAvatar) {
      avatarSlot = Padding(
        padding: EdgeInsets.only(
          left: isMe ? 0 : _avatarScreenMargin,
          right: isMe ? _avatarScreenMargin : 0,
        ),
        child: Avatar(
          name: effectiveName,
          url: effectiveAvatarUrl,
          size: _avatarSize,
        ),
      );
    } else if (reserveAvatarSpace) {
      avatarSlot = SizedBox(width: _avatarSize);
    } else {
      avatarSlot = const SizedBox.shrink();
    }

    // avatar 跟 bubble 之间的间距:仅 showAvatar=true 时加
    // (reserveAvatarSpace=false 即 dm_user_agent 不需要间距,避免 bubble 被挤到中间)
    final Widget avatarGap =
        showAvatar ? const SizedBox(width: 10) : const SizedBox.shrink();

    // 发送方:[StatusIcon?, Bubble, Avatar] 靠右
    if (isMe) {
      // 发送方布局拆两层:
      // - 内层 Row([status?, bubble]):crossAxisAlignment.center 让 status icon 垂直居中于气泡主体
      //   (bubble outerPadding=zero,bubble 高度 = BubbleWithTail 高度,中心精确对齐)
      // - 外层 Row([innerRow, avatarGap, avatarSlot]):crossAxisAlignment.start 让头像跟气泡顶部齐
      // bubble 用 IntrinsicWidth 让它按 bubble_inner 内容宽度(不撑满),status 紧贴 bubble 左侧。
      // maxBubbleWidth 按场景:dm_user_agent 0.9(单聊气泡宽,无头像不挤),
      //   其他场景 0.7(留余量给头像 + 屏幕右边距)
      // 有 status icon 时减去 24(icon 18 + right padding 6),防止:
      // bubble 撑到 maxBubbleWidth + status icon 把整体顶到右屏外
      final status = _statusIndicator;
      final double statusWidth = status != null ? 24 : 0;
      // 排队徽标:用户消息已被 agent 会话排队(queued=true)时,气泡左侧显示「排队中」。
      // 独立于发送状态(排队是「已送达 server 但 agent 未开始处理」,非 sending)。
      final bool showQueued = message.queued;
      final double queuedWidth = showQueued ? 40 : 0;
      final double widthRatio = reserveAvatarSpace ? 0.7 : 0.95;
      final double maxBubbleWidth =
          MediaQuery.sizeOf(context).width * widthRatio - statusWidth - queuedWidth;
      final bubbleWithStatus = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (status != null) status,
          if (showQueued)
            const Padding(
              padding: EdgeInsets.only(right: 4),
              child: Text('排队中',
                  style: TextStyle(fontSize: 11, color: Color(0xFF999999))),
            ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            // 方案 B:仅在此处把 bubble 包到 Column 中,引用块条件渲染在 bubble 上方,
            // 不改 bubbleWithStatus Row / sendRow Row / status icon 定位。
            // crossAxisAlignment.end 让 bubble 仍右对齐(发送方风格),
            // 引用块作为 Column 子项也跟随右对齐。
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.quote != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: MessageQuoteBlock(
                        quote: message.quote!,
                        isRevoked: isQuoteRevoked,
                        onTap: () =>
                            onJumpToMessage?.call(message.quote!.messageId),
                      ),
                    ),
                  bubble,
                ],
              ),
            ),
          ),
        ],
      );
      final sendRow = Row(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          bubbleWithStatus,
          avatarGap,
          avatarSlot,
        ],
      );
      return Padding(
        padding: reserveAvatarSpace
            ? const EdgeInsets.only(bottom: 8)
            : const EdgeInsets.only(left: 12, right: 12, bottom: 8),
        child: sendRow,
      );
    }

    // 接收方:[Avatar, Col([Nickname?, Bubble])] 靠左
    // maxBubbleWidth 跟发送方对称(无 status 需减):dm_user_agent 0.95,有头像场景 0.7
    final double widthRatio = reserveAvatarSpace ? 0.7 : 0.95;
    final double maxBubbleWidth =
        MediaQuery.sizeOf(context).width * widthRatio;
    final recvRow = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        avatarSlot,
        avatarGap,
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message.quote != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: MessageQuoteBlock(
                    quote: message.quote!,
                    isRevoked: isQuoteRevoked,
                    onTap: () =>
                        onJumpToMessage?.call(message.quote!.messageId),
                  ),
                ),
              if (nicknameShown)
                Padding(
                  padding: const EdgeInsets.only(left: 3, bottom: 2),
                  child: Text(
                    message.senderName!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w300,
                      color: Color(0xFF999999),
                    ),
                  ),
                ),
              // ConstrainedBox 显式 maxWidth 防止长内容撑满屏幕
              // (Flexible 会撑满 Row 减头像宽度,内容长时贴屏幕右边)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxBubbleWidth),
                child: bubble,
              ),
            ],
          ),
        ),
      ],
    );
    return Padding(
      padding: reserveAvatarSpace
          ? const EdgeInsets.only(bottom: 8)
          : const EdgeInsets.only(left: 12, right: 12, bottom: 8),
      child: recvRow,
    );
  }

  /// 状态指示器(sending: loading 圈;failed: 红色 ⚠,点击弹菜单)。
  /// 仅 isMe 且 status != sent 时返非 null。
  Widget? get _statusIndicator {
    if (message.isRecalled || message.status == MessageStatus.sent) {
      return null;
    }
    if (message.status == MessageStatus.sending) {
      return const Padding(
        padding: EdgeInsets.only(right: 6),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    // failed
    return GestureDetector(
      onTap: onFailedTap,
      child: const Padding(
        padding: EdgeInsets.only(right: 6),
        child: Icon(Icons.error_outline, color: Colors.red, size: 18),
      ),
    );
  }
}
