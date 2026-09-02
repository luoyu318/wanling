// 模板：新 Model 骨架（templates/flutter-model.dart.tmpl）
// Agent 子密钥条目(GET /api/agents/:id/subkeys):REST-only 授权密钥,
// server 永不下发 secret_key。详见 docs/ai-handbook/agent-subkeys.md。
library;

class AgentSubKeyInfo {
  final String id;
  final String name;
  final String agentId;
  final DateTime createdAt;

  /// 最后使用时间。活跃密钥为字段缺席(server omitempty)而非 null,解析须容忍。
  final DateTime? lastUsedAt;

  /// 吊销时间。非 null = 已吊销;字段缺席与 null 等价。
  final DateTime? revokedAt;

  const AgentSubKeyInfo({
    required this.id,
    required this.name,
    required this.agentId,
    required this.createdAt,
    this.lastUsedAt,
    this.revokedAt,
  });

  bool get isRevoked => revokedAt != null;

  // 审计 F5：fromJson/toJson 替代裸 Map<String, dynamic>
  factory AgentSubKeyInfo.fromJson(Map<String, dynamic> json) => AgentSubKeyInfo(
        id: json['id'] as String,
        name: json['name'] as String,
        agentId: json['agent_id'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        lastUsedAt: json['last_used_at'] == null
            ? null
            : DateTime.parse(json['last_used_at'] as String),
        revokedAt: json['revoked_at'] == null
            ? null
            : DateTime.parse(json['revoked_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'agent_id': agentId,
        'created_at': createdAt.toIso8601String(),
        if (lastUsedAt != null) 'last_used_at': lastUsedAt!.toIso8601String(),
        if (revokedAt != null) 'revoked_at': revokedAt!.toIso8601String(),
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentSubKeyInfo && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
