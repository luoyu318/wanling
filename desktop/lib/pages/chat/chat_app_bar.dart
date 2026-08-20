import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart';

import '../../providers/detail_panel_provider.dart';

/// 聊天区标题栏:会话名 + git 分支徽标(sessionMeta)+「详情」按钮,
/// 万灵路由下额外带「刷新」按钮(原万灵页 AppBar 迁入)。
///
/// 「详情」切换 [detailPanelOpenProvider](Task 7 接面板内容);
/// gitBranch 徽标展示 agent_session 的工作分支(sessionMeta.gitBranch)。
class ChatAppBar extends ConsumerWidget {
  final String title;
  final String? gitBranch;

  /// 当前聊天 agent:万灵路由刷新按钮联动其二级 session 列表。
  final String? agentId;

  const ChatAppBar({
    super.key,
    required this.title,
    this.gitBranch,
    this.agentId,
  });

  /// 是否处于 /wanling 路由(刷新按钮仅万灵页显示)。
  /// ChatView 单测直挂无 GoRouter 祖先,查不到路由视作非万灵页。
  static bool _onWanlingRoute(BuildContext context) {
    try {
      return GoRouterState.of(context).uri.path.startsWith('/wanling');
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final detailOpen = ref.watch(detailPanelOpenProvider);
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(bottom: BorderSide(color: Theme.of(context).dividerTheme.color ?? const Color(0xFFE4E4E4))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (gitBranch != null && gitBranch!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  _GitBranchBadge(branch: gitBranch!),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (_onWanlingRoute(context))
            IconButton(
              key: const ValueKey('agent_refresh'),
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: () {
                // 刷新 agent 列表 + 当前聊天 agent 的 session 列表
                // (左卡片二级列表同源数据)。
                ref.read(agentListProvider.notifier).load();
                final aid = agentId;
                if (aid != null) {
                  ref.read(agentSessionsProvider(aid).notifier).load();
                }
              },
            ),
          IconButton(
            tooltip: '详情',
            icon: Icon(
              detailOpen ? Icons.info : Icons.info_outline,
              size: 20,
              color: detailOpen ? scheme.primary : scheme.onSurface.withValues(alpha: 0.6),
            ),
            onPressed: () => ref.read(detailPanelOpenProvider.notifier).state =
                !detailOpen,
          ),
        ],
      ),
    );
  }
}

/// git 分支徽标:紧凑圆角胶囊,分支图标 + 分支名。
class _GitBranchBadge extends StatelessWidget {
  final String branch;

  const _GitBranchBadge({required this.branch});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.call_split,
            size: 12,
            color: scheme.onSurface.withValues(alpha: 0.55),
          ),
          const SizedBox(width: 4),
          Text(
            branch,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }
}
