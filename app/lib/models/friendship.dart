import 'user_summary.dart';

/// 好友关系状态机。
///
/// pending(初始)→ accepted / rejected / canceled。
/// 状态转换:
///   - 发起方 CreateRequest:无 → pending
///   - 接收方 Accept:pending → accepted
///   - 接收方 Reject:pending → rejected
///   - 发起方 Cancel:pending → canceled
///   - 任一方 RemoveFriend:accepted → 删除行
enum FriendshipStatus { pending, accepted, rejected, canceled }

extension FriendshipStatusX on FriendshipStatus {
  String get value => name;

  static FriendshipStatus fromString(String? raw) {
    switch (raw) {
      case 'accepted':
        return FriendshipStatus.accepted;
      case 'rejected':
        return FriendshipStatus.rejected;
      case 'canceled':
        return FriendshipStatus.canceled;
      case 'pending':
      default:
        return FriendshipStatus.pending;
    }
  }
}

/// 好友关系记录(对应 server friendships 表)。
class Friendship {
  final String id;
  final String userId; // 发起方 user_id
  final String friendId; // 接收方 user_id
  final FriendshipStatus status;
  final DateTime createdAt;
  final DateTime? respondedAt;

  Friendship({
    required this.id,
    required this.userId,
    required this.friendId,
    required this.status,
    required this.createdAt,
    this.respondedAt,
  });

  factory Friendship.fromJson(Map<String, dynamic> json) => Friendship(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        friendId: json['friend_id'] as String,
        status: FriendshipStatusX.fromString(json['status'] as String?),
        createdAt: DateTime.parse(json['created_at'] as String),
        respondedAt: json['responded_at'] != null
            ? DateTime.parse(json['responded_at'] as String)
            : null,
      );
}

/// 好友请求摘要(ListIncoming / ListOutgoing 返回)。
///
/// server 端拼装:friendship 行 + 对方 user 摘要(incoming 时 from_user,outgoing 时 to_user)。
/// 统一用 [user] 字段表示"对方",简化 client UI 渲染。
class FriendRequest {
  final String id;
  final FriendshipStatus status;
  final DateTime createdAt;
  final UserSummary user; // 对方摘要

  FriendRequest({
    required this.id,
    required this.status,
    required this.createdAt,
    required this.user,
  });

  factory FriendRequest.fromJson(Map<String, dynamic> json) => FriendRequest(
        id: (json['request_id'] as String?) ?? (json['id'] as String),
        status: FriendshipStatusX.fromString(json['status'] as String?),
        createdAt: DateTime.parse(json['created_at'] as String),
        user: UserSummary.fromJson(json['user'] as Map<String, dynamic>),
      );
}
