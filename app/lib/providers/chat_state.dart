import '../models/message.dart';

/// 聊天页面状态。包含消息列表 + 未读导航状态。
class ChatState {
  final List<ChatMessage> messages;     // newest first（与 reverse ListView 配合）
  final bool isLoadingMore;
  final bool hasMore;
  final int unreadCount;                // 未读数（历史未读 + 会话内新消息合并）
  final String? firstUnreadMessageId;   // 第一条未读消息 ID
  final bool showUnreadSeparator;       // 是否显示未读分隔线

  /// 首屏初始化中（_initialize 期间为 true）。
  /// 用于 ChatPage 显示 loading overlay：
  /// loading 期间 ListView 仍在树里（itemCount=0），让 ListViewObserver 的
  /// PostFrameCallback 提前注册 sliverContexts；state ready 后触发 jumpTo 时
  /// sliverContexts 已就绪，jumpTo 才能正常工作（修复 Bug A）。
  final bool isInitialLoading;

  const ChatState({
    this.messages = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
    this.unreadCount = 0,
    this.firstUnreadMessageId,
    this.showUnreadSeparator = false,
    this.isInitialLoading = true,
  });

  /// 未读浮标是否显示：还有剩余未读就显示（随上滑阅读递减到 0 才消失）。
  bool get shouldShowUnreadBadge => unreadCount > 0;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isLoadingMore,
    bool? hasMore,
    int? unreadCount,
    String? firstUnreadMessageId,
    bool clearFirstUnread = false,
    bool? showUnreadSeparator,
    bool? isInitialLoading,
  }) {
    return ChatState(
      messages: messages ?? this.messages,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      unreadCount: unreadCount ?? this.unreadCount,
      firstUnreadMessageId: clearFirstUnread
          ? null
          : (firstUnreadMessageId ?? this.firstUnreadMessageId),
      showUnreadSeparator: showUnreadSeparator ?? this.showUnreadSeparator,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
    );
  }
}
