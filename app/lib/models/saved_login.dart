/// 一条本地保存的登录组合(服务器 + 账号 + 密码)。
/// 唯一性:server + username。
class SavedLogin {
  final String server;
  final String username;
  final String password;

  const SavedLogin({
    required this.server,
    required this.username,
    required this.password,
  });

  /// 判断是否匹配给定 server + username(用于去重)。
  bool matches(String s, String u) => server == s && username == u;

  Map<String, dynamic> toJson() => {
        'server': server,
        'username': username,
        'password': password,
      };

  factory SavedLogin.fromJson(Map<String, dynamic> json) => SavedLogin(
        server: json['server'] as String,
        username: json['username'] as String,
        password: json['password'] as String,
      );

  SavedLogin copyWith({
    String? server,
    String? username,
    String? password,
  }) =>
      SavedLogin(
        server: server ?? this.server,
        username: username ?? this.username,
        password: password ?? this.password,
      );

  /// 相等性只看 server + username(唯一性约束),不看 password。
  /// 这样 Set 去重和 List.contains 能正确识别"同组合不同密码"。
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedLogin &&
          server == other.server &&
          username == other.username;

  @override
  int get hashCode => Object.hash(server, username);

  @override
  String toString() => 'SavedLogin($username @ $server)';
}
