/// Agent 在线状态。后端 status 字段是 "online" / "offline" 字符串。
/// 用 enum 集中定义、IDE 友好、避免拼写错误。
enum AgentStatus {
  online,
  offline,
  unknown;
}

extension AgentStatusX on AgentStatus {
  String get value => switch (this) {
        AgentStatus.online => 'online',
        AgentStatus.offline => 'offline',
        AgentStatus.unknown => 'unknown',
      };

  static AgentStatus fromString(String? raw) {
    switch (raw) {
      case 'online':
        return AgentStatus.online;
      case 'offline':
        return AgentStatus.offline;
      default:
        return AgentStatus.unknown;
    }
  }
}

class Agent {
  final String id;
  final String name;
  final String? avatarUrl;
  final String? bio;
  final AgentStatus status;
  final String? secretKey;

  Agent({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.bio,
    required this.status,
    this.secretKey,
  });

  factory Agent.fromJson(Map<String, dynamic> json) => Agent(
        id: json['id'],
        name: json['name'],
        avatarUrl: json['avatar_url'],
        bio: json['bio'],
        status: AgentStatusX.fromString(json['status']),
        secretKey: json['secret_key'],
      );

  /// copyWith 用 clearBio bool 区分 bio "不动"和"清空"。
  Agent copyWith({
    String? name,
    String? avatarUrl,
    String? bio,
    bool clearBio = false,
    AgentStatus? status,
  }) =>
      Agent(
        id: id,
        name: name ?? this.name,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        bio: clearBio ? null : (bio ?? this.bio),
        status: status ?? this.status,
        secretKey: secretKey,
      );
}
