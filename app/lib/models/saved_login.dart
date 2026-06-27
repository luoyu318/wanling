import 'account_mark.dart';

/// 一条本地保存的登录组合(服务器 + 账号 + 密码)。
/// 唯一性:server + username。
///
/// label 与 mark 为可选的显示用元数据,不参与唯一性判断。
class SavedLogin {
  final String server;
  final String username;
  final String password;
  final String? label;
  final AccountMark? mark;

  const SavedLogin({
    required this.server,
    required this.username,
    required this.password,
    this.label,
    this.mark,
  });

  /// 判断是否匹配给定 server + username(用于去重)。
  bool matches(String s, String u) => server == s && username == u;

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'server': server,
      'username': username,
      'password': password,
    };
    if (label != null) m['label'] = label;
    if (mark != null) m['mark'] = mark!.toJson();
    return m;
  }

  factory SavedLogin.fromJson(Map<String, dynamic> json) {
    AccountMark? mark;
    if (json['mark'] != null) {
      try {
        mark = AccountMark.fromJson(json['mark'] as Map<String, dynamic>);
      } catch (_) {
        // 老数据或损坏:降级为无标记
        mark = null;
      }
    }
    return SavedLogin(
      server: json['server'] as String,
      username: json['username'] as String,
      password: json['password'] as String,
      label: json['label'] as String?,
      mark: mark,
    );
  }

  SavedLogin copyWith({
    String? server,
    String? username,
    String? password,
    String? label,
    AccountMark? mark,
  }) =>
      SavedLogin(
        server: server ?? this.server,
        username: username ?? this.username,
        password: password ?? this.password,
        label: label ?? this.label,
        mark: mark ?? this.mark,
      );

  /// 相等性只看 server + username(唯一性约束),不看 password/label/mark。
  /// 这样 Set 去重和 List.contains 能正确识别"同组合不同密码/标记"。
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
