import 'package:flutter/material.dart';

import '../models/agent.dart' show AgentCategory;

/// Agent 类型标签胶囊。
///
/// 用于会话列表 / Agent 列表项的昵称右侧,按 agent.type 区分:
/// - Hermes:「Hermes」金色系(浅金底 + 深棕字)
/// - 开发型(opencode):「OpenCode」绿色系
/// - legacy / 空 type:「智能体」紫色系
///
/// 背景按 [elevated] 切两档(白底列表 vs 灰底 AppBar 保证对比度)。
class AgentBadge extends StatelessWidget {
  final String type;

  /// 是否在灰底(AppBar)上渲染。true 用更深背景保证对比度。
  final bool elevated;

  const AgentBadge({super.key, this.type = '', this.elevated = false});

  @override
  Widget build(BuildContext context) {
    final String label;
    final Color bg;
    final Color fg;

    if (type == AgentCategory.hermes) {
      label = 'Hermes';
      bg = elevated ? const Color(0xFFFDE68A) : const Color(0xFFFEF3C7);
      fg = const Color(0xFF78350F);
    } else if (AgentCategory.supportsMultiSession(type)) {
      label = 'OpenCode';
      bg = elevated ? const Color(0xFFA7F3D0) : const Color(0xFFD1FAE5);
      fg = const Color(0xFF047857);
    } else {
      label = '智能体';
      bg = elevated ? const Color(0xFFDDD6FE) : const Color(0xFFEDE9FE);
      fg = const Color(0xFF6D28D9);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: fg,
          height: 1.5,
        ),
      ),
    );
  }
}
