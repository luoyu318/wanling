import '../models/message.dart';

/// 聊天页面状态。包含消息列表 + 未读导航状态。
class ChatState {
  final List<ChatMessage> messages;     // newest first（与 reverse ListView 配合）
  final bool isLoadingMore;
  final bool hasMore;
  final int unreadCount;                // 进入会话时的历史未读数
  final String? firstUnreadMessageId;   // 第一条未读消息 ID
  final int newMessageCount;            // 会话内实时收到的新消息数
  final bool showUnreadSeparator;       // 是否显示未读分隔线

  /// 首屏初始化中（_initialize 期间为 true）。
  /// 用于 ChatPage 显示 loading overlay：
  /// loading 期间 ListView 仍在树里（itemCount=0），让 ListViewObserver 的
  /// PostFrameCallback 提前注册 sliverContexts；state ready 后触发 jumpTo 时
  /// sliverContexts 已就绪，jumpTo 才能正常工作（修复 Bug A）。
  final bool isInitialLoading;

  /// 少未读阈值：未读数 ≤ 此值时不显示蓝色浮标
  static const int badgeThreshold = 5;

  const ChatState({
    this.messages = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
    this.unreadCount = 0,
    this.firstUnreadMessageId,
    this.newMessageCount = 0,
    this.showUnreadSeparator = false,
    this.isInitialLoading = true,
  });

  /// 蓝色未读浮标是否显示：进入会话时历史未读 > 阈值（提示「N 条未读」跳到第一条未读）
  bool get shouldShowUnreadBadge => unreadCount > badgeThreshold;

  /// 绿色新消息浮标是否显示：会话内收到新消息（点此跳到底部看新消息）
  /// 与蓝色浮标语义不同，允许共存（少见场景：进入时历史未读>阈值 + 会话内又来新消息）
  bool get shouldShowNewMessageBadge => newMessageCount > 0;

  ChatState copyWith({
    List<ChatMessage>? messages,
    bool? isLoadingMore,
    bool? hasMore,
    int? unreadCount,
    String? firstUnreadMessageId,
    int? newMessageCount,
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
      newMessageCount: newMessageCount ?? this.newMessageCount,
      showUnreadSeparator: showUnreadSeparator ?? this.showUnreadSeparator,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
    );
  }
}
