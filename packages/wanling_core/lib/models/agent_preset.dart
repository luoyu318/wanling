// packages/wanling_core/lib/models/agent_preset.dart
/// Agent 会话预设(plugin 上报,能力上报管线第五成员)。
/// 预设是 per-session 能力组合(dsh 等平台),集合开放(user 可自创)。
/// trust 区分 system(部署内置)/user(用户自创,权限等同 shell 访问),
/// APP 据此显示来源标识;order 为可选排序位(缺省 0 排后)。
class AgentPreset {
  final String id;
  final String label;
  final String description;
  /// 'system' | 'user'。
  final String trust;
  final int order;

  const AgentPreset({
    required this.id,
    required this.label,
    this.description = '',
    this.trust = 'system',
    this.order = 0,
  });

  factory AgentPreset.fromJson(Map<String, dynamic> json) {
    return AgentPreset(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      description: json['description'] as String? ?? '',
      trust: json['trust'] as String? ?? 'system',
      order: json['order'] as int? ?? 0,
    );
  }
}
