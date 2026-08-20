import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart';
import 'package:wanling_core/providers/auth_provider.dart';

import 'avatar.dart';

/// agent 二级 session 列表面板(消息页/万灵页左栏共用)。
///
/// 仿 app 逻辑:一级列表按 agent.type 路由(supportsMultiSession → 二级)。
/// 数据源 core agentSessionsProvider(agentId)(agent_session 会话不在
/// conversationProvider 内,WS 实时刷新 last_message/unread)。
/// 布局:顶部返回头 + session 列表;点击回调 [onOpenSession](convId +
/// agentId 一起传,agent_session 查不到 agent,靠 selectedAgentIdProvider
/// 兜底)。
class AgentSessionsPane extends ConsumerWidget {
  final String agentId;
  final VoidCallback onBack;
  final void Function(String convId, String agentId) onOpenSession;

  const AgentSessionsPane({
    super.key,
    required this.agentId,
    required this.onBack,
    required this.onOpenSession,
  });

  /// 简单时间格式化:今天 HH:mm,否则 MM-dd。
  static String _formatTime(DateTime t) {
    final local = t.toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}-${local.day}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(agentSessionsProvider(agentId));
    final scheme = Theme.of(context).colorScheme;
    final currentUserId = ref.watch(
      authProvider.select((s) => s.user?.id ?? ''),
    );

    return Column(
      children: [
        // 返回头:返回一级列表。
        InkWell(
          key: const ValueKey('agent_sessions_back'),
          onTap: onBack,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.arrow_back,
                  size: 18,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 6),
                Text(
                  '会话列表',
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: sessions == null
              ? Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary.withValues(alpha: 0.6),
                    ),
                  ),
                )
              : sessions.isEmpty
                  ? Center(
                      child: Text(
                        '该万灵暂无会话',
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurface.withValues(alpha: 0.35),
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: ValueKey('agent_sessions_$agentId'),
                      itemCount: sessions.length,
                      itemBuilder: (_, i) {
                        final s = sessions[i];
                        return _SessionTile(
                          conv: s,
                          onTap: () => onOpenSession(s.id, agentId),
                          time: _formatTime(s.lastMessageAt),
                          currentUserId: currentUserId,
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

/// session 列表项:头像 + 名称 + 摘要 + 时间(未读 badge 在头像右上)。
class _SessionTile extends StatelessWidget {
  final Conversation conv;
  final String time;
  final String currentUserId;
  final VoidCallback onTap;

  const _SessionTile({
    required this.conv,
    required this.time,
    required this.currentUserId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: ValueKey('agent_session_${conv.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Avatar(
              name: conv.displayName,
              url: conv.displayAvatarUrl,
              size: 36,
              radius: 8,
              unreadCount: conv.unreadCount,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conv.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: scheme.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    conv.lastMessagePreview(
                      currentUserId: currentUserId,
                      isGroup: conv.isGroup,
                      senderDisplayName: conv.lastMessageSenderName,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              time,
              style: TextStyle(
                fontSize: 11,
                color: scheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
