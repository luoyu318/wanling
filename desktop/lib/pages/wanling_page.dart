import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import '../providers/no_conversation_hint_provider.dart';
import '../providers/selected_conv_provider.dart';
import '../widgets/agent_sessions_pane.dart';
import '../widgets/avatar.dart';
import 'chat/chat_view.dart';

/// 万灵页:左栏 agent 列表 + 右侧聊天框(与消息页同构的双栏)。
///
/// 仿 app 逻辑:
/// - 左栏一级:agent 列表(在线状态徽标 + bio),数据源 core agentListProvider;
/// - 点击 opencode 类 agent:左栏进入二级 session 列表(core
///   agentSessionsProvider(agentId),agent_session 会话不在
///   conversationProvider 内),带返回;
/// - 点击非 opencode agent(hermes 等单会话型):右栏直接打开该 agent 最新会话;
/// - 右侧一直是聊天框:选中会话挂 ChatView,未选中显示空态(无会话 agent 的
///   提示走 noConversationHintProvider,选中会话即清除)。
///
/// 选中态与消息页共享 selectedConvProvider,两页切换选中不丢。
class WanlingPage extends ConsumerStatefulWidget {
  const WanlingPage({super.key});

  @override
  ConsumerState<WanlingPage> createState() => _WanlingPageState();
}

class _WanlingPageState extends ConsumerState<WanlingPage> {
  /// 左栏二级模式:选中的 opencode agent(null = 一级 agent 列表)。
  String? _sessionsAgentId;

  @override
  Widget build(BuildContext context) {
    // 切到具体会话即清除无会话提示(右栏空态被会话取代)。
    ref.listen(selectedConvProvider, (prev, next) {
      if (next != null) {
        ref.read(noConversationHintProvider.notifier).state = null;
      }
    });

    final selectedId = ref.watch(selectedConvProvider);
    final agentId = selectedId == null
        ? null
        // agent_session 会话不在 conversationProvider 内,查不到时用
        // selectedAgentIdProvider 兜底(二级列表跳转时写入)。
        : ref
              .watch(conversationProvider)
              .where((c) => c.id == selectedId)
              .firstOrNull
              ?.agent
              ?.id ??
              ref.watch(selectedAgentIdProvider);

    final chatArea = Container(
      key: ValueKey('wanling_chat_area_$selectedId'),
      color: Theme.of(context).scaffoldBackgroundColor,
      child: selectedId == null
          ? _EmptyChatPane(hint: ref.watch(noConversationHintProvider))
          : ChatView(
              key: ValueKey('wanling_chat_view_$selectedId'),
              convId: selectedId,
              agentId: agentId,
            ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('万灵'),
        actions: [
          IconButton(
            key: const ValueKey('agent_refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () {
              ref.read(agentListProvider.notifier).load();
              final sid = _sessionsAgentId;
              if (sid != null) {
                ref.read(agentSessionsProvider(sid).notifier).load();
              }
            },
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(width: 300, child: _buildLeftPane(context)),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: chatArea),
        ],
      ),
    );
  }

  /// 左栏:一级 agent 列表 / 二级 session 列表(带返回头)。
  Widget _buildLeftPane(BuildContext context) {
    if (_sessionsAgentId != null) {
      return AgentSessionsPane(
        agentId: _sessionsAgentId!,
        onBack: () => setState(() => _sessionsAgentId = null),
        onOpenSession: _openConversation,
      );
    }
    return _AgentListPane(
      onAgentTap: _onAgentTap,
      selectedConvId: ref.watch(selectedConvProvider),
    );
  }

  void _onAgentTap(Agent agent) {
    if (agent.type == AgentCategory.opencode) {
      // opencode:左栏进入二级 session 列表。
      setState(() => _sessionsAgentId = agent.id);
      return;
    }
    // 非 opencode:右栏直接打开该 agent 最新会话;无会话写提示。
    final convs = ref
        .read(conversationProvider)
        .where((c) => c.agent?.id == agent.id)
        .toList()
      ..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));

    if (convs.isEmpty) {
      ref.read(selectedConvProvider.notifier).state = null;
      ref.read(selectedAgentIdProvider.notifier).state = null;
      ref.read(noConversationHintProvider.notifier).state =
          '该 Agent 暂无会话，可从消息页发起';
      return;
    }
    _openConversation(convs.first.id, agent.id);
  }

  /// 选中会话 + agentId 兜底写入,右栏聊天框打开。
  void _openConversation(String convId, String agentId) {
    ref.read(selectedConvProvider.notifier).state = convId;
    ref.read(selectedAgentIdProvider.notifier).state = agentId;
  }
}

/// 右栏空态:未选中会话时的占位(含无会话 agent 提示)。
class _EmptyChatPane extends StatelessWidget {
  final String? hint;

  const _EmptyChatPane({this.hint});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.forum_outlined,
            size: 48,
            color: scheme.onSurface.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 12),
          Text(
            '选择左侧会话开始聊天',
            style: TextStyle(
              fontSize: 14,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint!,
              key: const ValueKey('no_conv_hint'),
              style: TextStyle(fontSize: 13, color: scheme.primary),
            ),
          ],
        ],
      ),
    );
  }
}

/// 一级 agent 列表。
class _AgentListPane extends ConsumerWidget {
  final void Function(Agent agent) onAgentTap;
  final String? selectedConvId;

  const _AgentListPane({required this.onAgentTap, this.selectedConvId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentListProvider);
    final scheme = Theme.of(context).colorScheme;
    if (agents.isEmpty) {
      return Center(
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
      );
    }
    return ListView.builder(
      itemCount: agents.length,
      itemBuilder: (_, i) => _AgentCard(
        agent: agents[i],
        onTap: () => onAgentTap(agents[i]),
      ),
    );
  }
}

/// agent 卡片行:头像(真图兜底色块) + name + type 徽标 + 在线状态点 + bio。
class _AgentCard extends StatelessWidget {
  final Agent agent;
  final VoidCallback onTap;

  const _AgentCard({required this.agent, required this.onTap});

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
            Avatar(name: agent.name, url: agent.avatarUrl, size: 36, radius: 18),
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
