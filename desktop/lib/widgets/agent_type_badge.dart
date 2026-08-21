import 'package:flutter/material.dart';
import 'package:wanling_core/models/agent.dart' show AgentCategory;

/// agent type 实心胶囊徽章。
///
/// 样式复刻 app widgets/agent_badge.dart(改时两处同步),三档:
/// Hermes 琥珀 / OpenCode 绿 / 兜底紫「智能体」。
/// 使用方:会话列表项(conversation_list_item)/ 万灵页 agent 卡片
/// (wanling_page)。
class AgentTypeBadge extends StatelessWidget {
  final String type;

  const AgentTypeBadge({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color bg;
    final Color fg;
    if (type == AgentCategory.hermes) {
      label = 'Hermes';
      bg = const Color(0xFFFEF3C7);
      fg = const Color(0xFF78350F);
    } else if (AgentCategory.supportsMultiSession(type)) {
      label = 'OpenCode';
      bg = const Color(0xFFD1FAE5);
      fg = const Color(0xFF047857);
    } else {
      label = '智能体';
      bg = const Color(0xFFEDE9FE);
      fg = const Color(0xFF6D28D9);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: fg, height: 1.5),
      ),
    );
  }
}
