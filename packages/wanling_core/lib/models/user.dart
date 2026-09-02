class User {
  final String id;
  final String username;
  final String? nickname;
  final String? bio;
  final String? avatarUrl;
  final DateTime createdAt;
  /// 账号角色（user / admin）。旧 server 无此字段时缺省 user。
  final String role;

  User({
    required this.id,
    required this.username,
    this.nickname,
    this.bio,
    this.avatarUrl,
    required this.createdAt,
    this.role = 'user',
  });

  /// 展示名：昵称非空用昵称，否则回退账号 username。
  String get displayName =>
      (nickname != null && nickname!.isNotEmpty) ? nickname! : username;

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'],
        username: json['username'],
        nickname: json['nickname'],
        bio: json['bio'],
        avatarUrl: json['avatar_url'],
        createdAt: DateTime.parse(json['created_at']),
        role: json['role'] as String? ?? 'user',
      );

  /// copyWith 用 clearXxx bool 区分"不动"和"清空"：
  /// Dart String? 参数无法区分"传 null=不动"和"传 null=清空"。
  User copyWith({
    String? username,
    String? nickname,
    bool clearNickname = false,
    String? bio,
    bool clearBio = false,
    String? avatarUrl,
  }) =>
      User(
        id: id,
        username: username ?? this.username,
        nickname: clearNickname ? null : (nickname ?? this.nickname),
        bio: clearBio ? null : (bio ?? this.bio),
        avatarUrl: avatarUrl ?? this.avatarUrl,
        createdAt: createdAt,
        // role 不随资料编辑变更,copyWith 无 role 参数,仅透传保留
        role: role,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'username': username,
        'nickname': nickname,
        'bio': bio,
        'avatar_url': avatarUrl,
        'created_at': createdAt.toIso8601String(),
        'role': role,
      };
}
