class UnreadInfo {
  final int unreadCount;
  final String? firstUnreadMessageId;
  /// 第一条未读消息的创建时间。无未读时为 null。
  /// 直接用作游标分页的 after 参数（无需再查消息详情）。
  final DateTime? firstUnreadCreatedAt;

  /// firstUnread 之前是否还有已读历史消息。
  /// ListAfter 只取未读方向，loaded.length 满 _pageSize 不能反映 firstUnread
  /// 之前是否还有历史，故由服务端独立 count 后告知。
  /// APP 用此字段决定 hasMore：是否允许上滑加载历史（修复 hasMore 误判 bug）。
  /// 无未读时为 false（此字段无意义）。
  final bool hasMoreBeforeFirstUnread;

  const UnreadInfo({
    required this.unreadCount,
    this.firstUnreadMessageId,
    this.firstUnreadCreatedAt,
    this.hasMoreBeforeFirstUnread = false,
  });

  factory UnreadInfo.fromJson(Map<String, dynamic> json) {
    final idRaw = json['first_unread_message_id'];
    final createdAtRaw = json['first_unread_created_at'];
    return UnreadInfo(
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      // 服务端无未读时返回空字符串，统一规范化为 null
      firstUnreadMessageId:
          (idRaw is String && idRaw.isNotEmpty) ? idRaw : null,
      firstUnreadCreatedAt:
          (createdAtRaw is String && createdAtRaw.isNotEmpty)
              ? DateTime.parse(createdAtRaw)
              : null,
      hasMoreBeforeFirstUnread: json['has_more_before_first_unread'] == true,
    );
  }
}
