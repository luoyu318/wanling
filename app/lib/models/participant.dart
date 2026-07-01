/// 会话参与者摘要。
///
/// 对应 server 端 BatchLoadParticipantSummaries 返回的结构:
///   - member_id:user 或 agent 的 UUID
///   - member_type:'user' 或 'agent'
///   - role:'owner' / 'admin' / 'member'(本期 admin 字段保留但不实现业务)
///   - username/nickname/avatarUrl:渲染用摘要(member_type='agent' 时 username 用 agent.name)
class Participant {
  final String memberId;
  final String memberType;
  final String role;
  final String username;
  final String nickname;
  final String avatarUrl;

  Participant({
    required this.memberId,
    required this.memberType,
    required this.role,
    required this.username,
    required this.nickname,
    required this.avatarUrl,
  });

  factory Participant.fromJson(Map<String, dynamic> json) {
    final username = json['username'] as String? ?? '';
    return Participant(
      memberId: json['member_id'] as String,
      memberType: json['member_type'] as String,
      role: json['role'] as String? ?? 'member',
      username: username,
      // nickname 缺失时回退 username(对齐 server COALESCE 逻辑)
      nickname: (json['nickname'] as String?)?.isNotEmpty == true
          ? json['nickname'] as String
          : username,
      avatarUrl: json['avatar_url'] as String? ?? '',
    );
  }

  // === 便利 getter ===

  bool get isUser => memberType == 'user';
  bool get isAgent => memberType == 'agent';
  bool get isOwner => role == 'owner';
  bool get isAdmin => role == 'admin';

  /// 显示名(优先 nickname)。
  String get displayName =>
      nickname.isNotEmpty ? nickname : username;
}
