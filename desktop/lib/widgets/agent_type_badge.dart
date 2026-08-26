import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/models/agent_type_info.dart';
import 'package:wanling_core/providers/agent_types_provider.dart';

/// agent type 实心胶囊徽章。
///
/// 文案/配色来自 server type 注册表(agentTypesProvider 查表),与 app 端
/// widgets/agent_badge.dart 同口径(改时两处同步):注册表值优先,本地
/// fallbackTypes 兜老 server,未注册类型显示 type 原文+默认紫配色,
/// legacy 空串显示「智能体」。
/// 使用方:会话列表项(conversation_list_item)/ 万灵页 agent 卡片
/// (wanling_page)。
class AgentTypeBadge extends ConsumerWidget {
  final String type;

  const AgentTypeBadge({super.key, required this.type});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final registered = {
      for (final t in AgentTypeInfo.fallbackTypes) t.type: t,
      for (final t in ref.watch(agentTypesProvider).valueOrNull ??
          const <AgentTypeInfo>[])
        t.type: t,
    };
    final info = registered[type];

    final String label;
    final Color bg;
    final Color fg;
    if (info != null) {
      label = info.label;
      bg = _parseColor(info.badgeBg, _defaultBg);
      fg = _parseColor(info.badgeFg, _defaultFg);
    } else if (type.isEmpty) {
      label = '智能体';
      bg = _defaultBg;
      fg = _defaultFg;
    } else {
      label = type;
      bg = _defaultBg;
      fg = _defaultFg;
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

  static const _defaultBg = Color(0xFFEDE9FE);
  static const _defaultFg = Color(0xFF6D28D9);

  static Color _parseColor(String hex, Color fallback) {
    final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    return v == null ? fallback : Color(0xFF000000 | v);
  }
}
