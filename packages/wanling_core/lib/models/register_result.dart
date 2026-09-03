/// 注册接口返回结果：access token + refresh token + role（注册后调 /me 拉 user）。
class RegisterResult {
  final String token;
  final String refreshToken;
  /// 当前账号角色（user / admin）。旧 server 无此字段时缺省 user。
  final String role;

  RegisterResult({
    required this.token,
    required this.refreshToken,
    this.role = 'user',
  });

  factory RegisterResult.fromJson(Map<String, dynamic> json) {
    return RegisterResult(
      token: json['token'] as String,
      refreshToken: json['refresh_token'] as String? ?? '',
      role: json['role'] as String? ?? 'user',
    );
  }
}
