import 'package:flutter/material.dart';

import '../agent_badge.dart';

/// ChatPage 的 AppBar,支持多选/普通双模式。
///
/// - 多选模式:深色 AppBar(close + "已选择 N 条")
/// - 普通模式:灰色 AppBar(agentName + AgentBadge + subtitle + 详情按钮)
class ChatAppBar extends StatelessWidget implements PreferredSizeWidget {
  final bool selectionMode;
  final int selectedCount;
  final VoidCallback onExitSelection;
  final String agentName;
  final Widget? subtitle;

  /// 是否显示 Agent 类型标签。
  /// convForStatus?.isUserAgentDM ||
  /// (isAgentSession && AgentCategory.supportsMultiSession(agentTypeForBadge))
  final bool showBadge;

  /// Agent 类型(convForStatus?.agent?.type ?? agentTypeForBadge ?? '')
  final String badgeType;
  final VoidCallback onDetailTap;

  const ChatAppBar({
    super.key,
    required this.selectionMode,
    required this.selectedCount,
    required this.onExitSelection,
    required this.agentName,
    required this.subtitle,
    required this.showBadge,
    required this.badgeType,
    required this.onDetailTap,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    if (selectionMode) {
      return AppBar(
        backgroundColor: const Color(0xFF2A2A2A),
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: onExitSelection,
        ),
        title: Text('已选择 $selectedCount 条'),
        centerTitle: true,
      );
    }

    return AppBar(
      backgroundColor: const Color(0xFFEDEDED),
      surfaceTintColor: Colors.transparent,
      // 下边框:极细线,深于背景色
      shape: const Border(
        bottom: BorderSide(color: Color(0xFFD9D9D9), width: 0.5),
      ),
      centerTitle: true,
      title: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  agentName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ),
              // dm_user_agent 显 agent 类型标签;agent_session 仅开发型(opencode)才显
              // (conv 未 load 时不显,避免 user-user 闪现)
              // elevated=true:AppBar 灰底用更深背景保证对比度
              if (showBadge) ...[
                const SizedBox(width: 4),
                AgentBadge(type: badgeType, elevated: true),
              ],
            ],
          ),
          // 副标题:agent_session 显 session meta,dm_user_agent 显在线状态。
          // 其他场景 subtitle=null,不渲染。
          ?subtitle,
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.more_vert),
          tooltip: '会话详情',
          onPressed: onDetailTap,
        ),
      ],
    );
  }
}
