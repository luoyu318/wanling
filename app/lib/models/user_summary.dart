/// 用户摘要(server SearchByUsername / friend 摘要响应用)。
///
/// 关键约束:**不含 user_id**(spec §4.2 防止 username 枚举泄漏 user_id)。
/// client 端发起加好友请求时,用 username 作为参数(server 内部反查 user_id)。
class UserSummary {
  final String username;
  final String nickname;
  final String avatarUrl;

  UserSummary({
    required this.username,
    required this.nickname,
    required this.avatarUrl,
  });

  factory UserSummary.fromJson(Map<String, dynamic> json) {
    final username = json['username'] as String? ?? '';
    return UserSummary(
      username: username,
      nickname: (json['nickname'] as String?)?.isNotEmpty == true
          ? json['nickname'] as String
          : username,
      avatarUrl: json['avatar_url'] as String? ?? '',
    );
  }

  /// 显示名(优先 nickname)。
  String get displayName =>
      nickname.isNotEmpty ? nickname : username;
}
