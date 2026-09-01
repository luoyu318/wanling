import 'user.dart';

/// 登录接口返回结果：JWT access token + refresh token + 当前 user + role。
class LoginResult {
  final String token;
  final String refreshToken;
  final User user;
  /// 当前账号角色（user / admin）。旧 server 无此字段时缺省 user。
  final String role;

  LoginResult({
    required this.token,
    required this.refreshToken,
    required this.user,
    this.role = 'user',
  });

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    return LoginResult(
      token: json['token'] as String,
      refreshToken: json['refresh_token'] as String? ?? '',
      role: json['role'] as String? ?? 'user',
      user: User.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}
