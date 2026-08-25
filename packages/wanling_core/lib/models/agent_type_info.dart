/// Agent type 注册表条目(GET /api/agent-types)。
/// server 统一下发的类型属性:拓扑(multi_session)决定路由,
/// 展示(label/badge 配色)供徽标与类型下拉;新类型注册后 APP 零发版可见。
library;

class AgentTypeInfo {
  final String type;
  final bool multiSession;
  final String label;
  final String badgeBg;
  final String badgeBgElevated;
  final String badgeFg;

  const AgentTypeInfo({
    required this.type,
    required this.multiSession,
    required this.label,
    this.badgeBg = '',
    this.badgeBgElevated = '',
    this.badgeFg = '',
  });

  factory AgentTypeInfo.fromJson(Map<String, dynamic> json) => AgentTypeInfo(
        type: json['type'] as String,
        multiSession: json['multi_session'] as bool? ?? false,
        label: json['label'] as String? ?? '',
        badgeBg: json['badge_bg'] as String? ?? '',
        badgeBgElevated: json['badge_bg_elevated'] as String? ?? '',
        badgeFg: json['badge_fg'] as String? ?? '',
      );

  /// 老 server(无 /api/agent-types)/加载失败时的本地兜底清单。
  /// 与 server migrations/011 预置数据保持一致。
  static const fallbackTypes = <AgentTypeInfo>[
    AgentTypeInfo(type: 'hermes', multiSession: false, label: 'Hermes',
        badgeBg: '#FEF3C7', badgeBgElevated: '#FDE68A', badgeFg: '#78350F'),
    AgentTypeInfo(type: 'opencode', multiSession: true, label: 'OpenCode',
        badgeBg: '#D1FAE5', badgeBgElevated: '#A7F3D0', badgeFg: '#047857'),
    AgentTypeInfo(type: 'dsh', multiSession: true, label: 'DSH',
        badgeBg: '#E0F2FE', badgeBgElevated: '#BAE6FD', badgeFg: '#075985'),
  ];
}
