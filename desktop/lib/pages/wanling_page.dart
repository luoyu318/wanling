import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import '../providers/no_conversation_hint_provider.dart';
import '../providers/selected_conv_provider.dart'
    show selectedWanlingAgentIdProvider, selectedWanlingConvProvider;
import '../shell/card_container.dart';
import '../widgets/agent_type_badge.dart';
import '../theme/desktop_theme.dart';
import '../widgets/avatar.dart';
import 'chat/chat_view.dart';

/// 万灵页(卡片化后):仅聊天卡片内容(空态 / ChatView),由 DesktopShell
/// 装进 AppCanvas 聊天卡槽。左栏 agent 列表两级导航上移
/// DesktopShell._ConversationCardHost;刷新按钮移 ChatAppBar(仅
/// /wanling 路由显示)。
///
/// 选中态用万灵 tab 独立的 selectedWanlingConvProvider(与消息 tab 的
/// selectedConvProvider 隔离):消息页聊着天切到万灵,右侧不残留消息
/// 页会话;仅万灵 tab 内(二级列表/详情页 CTA)打开的会话显示。
/// agentId 兜底逻辑与消息页同构(agent_session 不在 conversationProvider
/// 内,查不到时用 selectedWanlingAgentIdProvider 兜底)。
class WanlingPage extends ConsumerWidget {
  const WanlingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 切到具体会话即清除无会话提示(空态被会话取代)。
    ref.listen(selectedWanlingConvProvider, (prev, next) {
      if (next != null) {
        ref.read(noConversationHintProvider.notifier).state = null;
      }
    });

    final selectedId = ref.watch(selectedWanlingConvProvider);
    final agentId = selectedId == null
        ? null
        : ref
              .watch(conversationProvider)
              .where((c) => c.id == selectedId)
              .firstOrNull
              ?.agent
              ?.id ??
              ref.watch(selectedWanlingAgentIdProvider);

    return CardContainer(
      key: ValueKey('wanling_chat_area_$selectedId'),
      color: DesktopTheme.chatCardColor(Theme.of(context).brightness),
      child: selectedId == null
          ? _EmptyChatPane(hint: ref.watch(noConversationHintProvider))
          : ChatView(
              key: ValueKey('wanling_chat_view_$selectedId'),
              convId: selectedId,
              agentId: agentId,
            ),
    );
  }
}

/// 右侧聊天卡空态:未选中会话时的占位(含无会话 agent 提示)。
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

/// 一级 agent 列表(公开:DesktopShell 会话卡片宿主的万灵分支消费)。
/// 数据源 core agentListProvider(在线状态徽标 + bio)。
class WanlingAgentListPane extends ConsumerWidget {
  final void Function(Agent agent) onAgentTap;

  const WanlingAgentListPane({super.key, required this.onAgentTap});

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
                      // 空 type(legacy 普通 agent)也渲染徽标,显示「智能体」。
                      const SizedBox(width: 6),
                      AgentTypeBadge(type: agent.type),
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
