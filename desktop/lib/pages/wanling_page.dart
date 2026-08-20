import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import '../providers/no_conversation_hint_provider.dart';
import '../providers/selected_conv_provider.dart';

/// 万灵页:agent 列表(在线状态徽标 + bio)+ 点击进该 agent 的最新会话。
///
/// - 数据源 core agentListProvider(AGENT_ONLINE/OFFLINE WS 实时刷新 status);
/// - 点击卡片:过滤 conversationProvider 中该 agent 的会话,取 lastMessageAt
///   最新者写入 selectedConvProvider + context.go('/messages')双栏接线;
/// - 无会话时(OpenCode 等主 agent 的 agent_session 不在 provider 内):仍切
///   /messages,清空选中态使消息页空态展示 noConversationHintProvider 的提示。
class WanlingPage extends ConsumerWidget {
  const WanlingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentListProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('万灵'),
        actions: [
          IconButton(
            key: const ValueKey('agent_refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () => ref.read(agentListProvider.notifier).load(),
          ),
        ],
      ),
      body: agents.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.smart_toy_outlined,
                    size: 48,
                    color: scheme.onSurface.withValues(alpha: 0.2),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '暂无万灵',
                    style: TextStyle(
                      fontSize: 14,
                      color: scheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: agents.length,
              itemBuilder: (_, i) => _AgentCard(
                agent: agents[i],
                onTap: () => _openLatestConversation(context, ref, agents[i]),
              ),
            ),
    );
  }

  /// 过滤该 agent 的会话 → 选最新 → 跳 /messages。
  void _openLatestConversation(
    BuildContext context,
    WidgetRef ref,
    Agent agent,
  ) {
    final convs = ref
        .read(conversationProvider)
        .where((c) => c.agent?.id == agent.id)
        .toList()
      ..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));

    if (convs.isEmpty) {
      // 无匹配会话:不弹「暂无会话」对话框,清空选中态使消息页展示空态提示。
      ref.read(selectedConvProvider.notifier).state = null;
      ref.read(noConversationHintProvider.notifier).state =
          '该 Agent 暂无会话，可从消息页发起';
      context.go('/messages');
      return;
    }
    ref.read(selectedConvProvider.notifier).state = convs.first.id;
    context.go('/messages');
  }
}

/// agent 卡片行:色块头像兜底 + name + type 徽标 + 在线状态点 + bio。
class _AgentCard extends StatelessWidget {
  final Agent agent;
  final VoidCallback onTap;

  const _AgentCard({required this.agent, required this.onTap});

  /// 按 name 稳定取色(头像色块兜底,对齐 IM 惯例)。
  Color get _avatarColor => Colors.primaries[agent.name.hashCode.abs() % Colors.primaries.length];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final online = agent.status == AgentStatus.online;

    return InkWell(
      key: ValueKey('agent_${agent.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: _avatarColor.withValues(alpha: 0.85),
              child: Text(
                agent.name.isEmpty ? '?' : agent.name.characters.first,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          agent.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      if (agent.type.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _TypeBadge(type: agent.type),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        key: ValueKey('agent_status_dot_${agent.id}'),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: online
                              ? const Color(0xFF07C160)
                              : const Color(0xFFCCCCCC),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        online ? '在线' : '离线',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      if (agent.bio != null && agent.bio!.isNotEmpty) ...[
                        Text(
                          '  |  ',
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.25),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            agent.bio!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              size: 20,
              color: scheme.onSurface.withValues(alpha: 0.3),
            ),
          ],
        ),
      ),
    );
  }
}

/// agent 类型小徽标(OpenCode 多 session / Hermes 对话型)。
class _TypeBadge extends StatelessWidget {
  final String type;

  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        type == AgentCategory.opencode ? 'OpenCode' : type.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}
