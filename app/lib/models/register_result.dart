/// 注册接口返回结果：access token + refresh token（注册后调 /me 拉 user）。
class RegisterResult {
  final String token;
  final String refreshToken;

  RegisterResult({
    required this.token,
    required this.refreshToken,
  });

  factory RegisterResult.fromJson(Map<String, dynamic> json) {
    return RegisterResult(
      token: json['token'] as String,
      refreshToken: json['refresh_token'] as String? ?? '',
    );
  }
}
