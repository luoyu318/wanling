// packages/wanling_core/lib/models/agent_mode.dart
/// Agent 会话模式(plugin 上报,能力上报管线第四成员)。
/// APP 不理解 mode 业务语义,视觉差异由 style 档位自描述;
/// 渲染时按 session-meta mode id 查清单取 label/style。
class AgentMode {
  final String id;
  final String label;
  /// 受控渲染档位: default | plan | warn。
  final String style;

  const AgentMode({
    required this.id,
    required this.label,
    required this.style,
  });

  factory AgentMode.fromJson(Map<String, dynamic> json) {
    return AgentMode(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      style: json['style'] as String? ?? 'default',
    );
  }
}

/// 在上报清单中查当前会话 mode(id 大小写不敏感)。
/// 清单缺失/未命中返 null,调用方回退既有 'plan' 特例(老插件兼容期)。
AgentMode? findModeById(List<AgentMode> modes, String currentMode) {
  if (currentMode.isEmpty) return null;
  final lower = currentMode.toLowerCase();
  for (final m in modes) {
    if (m.id.toLowerCase() == lower) return m;
  }
  return null;
}

/// 模式渲染档位(app/desktop 双端统一映射,单一真相源):
/// default=品牌蓝 597BFF,plan=橙 F4A742,warn=警示红(如 danger-full-access)。
/// 色值常量随档位集中定义,两端不再各自硬编码。
enum AgentModeVisualStyle { brand, plan, warn }

extension AgentModeStyleX on String {
  AgentModeVisualStyle get visualStyle {
    switch (toLowerCase()) {
      case 'plan':
        return AgentModeVisualStyle.plan;
      case 'warn':
        return AgentModeVisualStyle.warn;
      default:
        return AgentModeVisualStyle.brand;
    }
  }
}
