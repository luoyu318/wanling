import 'user.dart';

/// 登录接口返回结果：JWT access token + refresh token + 当前 user。
class LoginResult {
  final String token;
  final String refreshToken;
  final User user;

  LoginResult({
    required this.token,
    required this.refreshToken,
    required this.user,
  });

  factory LoginResult.fromJson(Map<String, dynamic> json) {
    return LoginResult(
      token: json['token'] as String,
      refreshToken: json['refresh_token'] as String? ?? '',
      user: User.fromJson(json['user'] as Map<String, dynamic>),
    );
  }
}
