import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart';
import 'package:wanling_core/providers/agent_status_provider.dart' show agentStatusProvider, AgentStatusType;
import 'package:wanling_core/providers/typing_provider.dart' show typingProvider;
import 'package:wanling_core/widgets/chat/shimmer_text.dart';

import '../../providers/detail_panel_provider.dart';

/// 聊天区标题栏:会话名 + subtitle 打字/生成状态 + git 分支徽标(sessionMeta)
/// +「详情」按钮,万灵路由下额外带「刷新」按钮(原万灵页 AppBar 迁入)。
///
/// subtitle 口径对齐 app chat_page:
/// - 多聊(agent_session): agentStatusProvider busy → ShimmerText「灵光涌动...」
///   绿 / retry → 红字「重试中(第 N 次)...」;空闲不渲染。
/// - 单聊(dm_user_agent): TYPING_START → 「对方正在输入...」绿;否则在线状态。
///
/// 「详情」切换 [detailPanelOpenProvider](Task 7 接面板内容);
/// gitBranch 徽标展示 agent_session 的工作分支(sessionMeta.gitBranch)。
class ChatAppBar extends ConsumerWidget {
  final String title;
  final String? gitBranch;

  /// 当前聊天 agent:万灵路由刷新按钮联动其二级 session 列表。
  final String? agentId;

  /// 是否展示右侧「详情」入口。单聊 agent(dm_user_agent)传 false 隐藏。
  final bool showDetail;

  /// 会话类型(dm_user_agent / agent_session / ...):决定 subtitle 打字态口径
  /// (单聊=typing/生成态;多聊=agent 生成状态「灵光涌动」)。null 不渲染。
  final String? convType;

  /// 会话 id:agentStatusProvider / typingProvider 按 convId 键取本会话状态。
  final String convId;

  const ChatAppBar({
    super.key,
    required this.title,
    required this.convId,
    this.gitBranch,
    this.agentId,
    this.showDetail = true,
    this.convType,
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
        // 透明透出外层聊天卡片底色(Task 7 CardContainer)
        color: Colors.transparent,
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
                // subtitle 打字/生成状态(对齐 app 双口径,见类注释)。
                if (convType != null) ...[
                  const SizedBox(width: 10),
                  _Subtitle(
                    convType: convType!,
                    convId: convId,
                  ),
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
          if (showDetail)
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

/// AppBar 副标题:打字/生成状态(口径见 ChatAppBar 类注释)。
class _Subtitle extends ConsumerWidget {
  final String convType;
  final String convId;

  const _Subtitle({required this.convType, required this.convId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (convType == 'agent_session') {
      // 多聊:agent_status_provider 实时状态(busy=生成中 / retry=重试中),
      // select 只订阅本 conv,避免其他会话状态变化触发无谓 rebuild。
      final status = ref.watch(
        agentStatusProvider.select((s) => s[convId]),
      );
      if (status == null) return const SizedBox.shrink();
      if (status.type == AgentStatusType.busy) {
        return ShimmerText(
          text: '灵光涌动...',
          baseColor: const Color(0xFF07C160),
          style: const TextStyle(fontSize: 12),
        );
      }
      return ShimmerText(
        text: '重试中(第 ${status.attempt} 次)...',
        baseColor: const Color(0xFFE53935),
        style: const TextStyle(fontSize: 12),
      );
    }

    // 单聊:TYPING_START 打字态优先;agent 生成中(agentStatus 有值)同样显示。
    final typing = ref.watch(typingProvider.select((m) => m[convId] ?? false));
    final generating =
        ref.watch(agentStatusProvider.select((s) => s[convId])) != null;
    if (typing || generating) {
      return ShimmerText(
        text: '对方正在输入...',
        baseColor: const Color(0xFF07C160),
        style: const TextStyle(fontSize: 12),
      );
    }
    return const SizedBox.shrink();
  }
}
