import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/agent_type_info.dart';
import 'package:wanling_core/providers/agent_types_provider.dart';

/// Agent 类型标签胶囊。
///
/// 文案/配色来自 server type 注册表(GET /api/agent-types,agentTypesProvider
/// 查表),新类型 server 侧登记后自动正确展示,APP 零发版:
/// - 注册表命中:label + badge 配色(#RRGGBB)按下发值渲染
/// - 未命中/老 server/加载失败:label 显示 type 原文 + 紫色默认配色
/// - legacy / 空 type:「智能体」紫色系
///
/// 背景按 [elevated] 切两档(白底列表 vs 灰底 AppBar 保证对比度),
/// 注册表带 badge_bg / badge_bg_elevated 两列对应。
class AgentBadge extends ConsumerWidget {
  final String type;

  /// 是否在灰底(AppBar)上渲染。true 用更深背景保证对比度。
  final bool elevated;

  const AgentBadge({super.key, this.type = '', this.elevated = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 本地 fallback 仅兜老 server;server 注册表值优先(可覆盖 label/配色)。
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
      bg = _parseColor(elevated ? info.badgeBgElevated : info.badgeBg,
          _defaultBgFor(elevated));
      fg = _parseColor(info.badgeFg, _defaultFg);
    } else if (type.isEmpty) {
      // legacy 普通 agent(空串):「智能体」紫色系
      label = '智能体';
      bg = _defaultBgFor(elevated);
      fg = _defaultFg;
    } else {
      // 未注册新类型:显示 type 原文 + 默认配色(登记前过渡态)。
      label = type;
      bg = _defaultBgFor(elevated);
      fg = _defaultFg;
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

  static const _defaultBg = Color(0xFFEDE9FE);
  static const _defaultBgElevated = Color(0xFFDDD6FE);
  static const _defaultFg = Color(0xFF6D28D9);

  static Color _defaultBgFor(bool elevated) =>
      elevated ? _defaultBgElevated : _defaultBg;

  static Color _parseColor(String hex, Color fallback) {
    final v = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
    return v == null ? fallback : Color(0xFF000000 | v);
  }
}
