import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/conversation_provider.dart';
import '../providers/selected_conv_provider.dart';
import '../widgets/conversation_list.dart';
import 'chat/chat_view.dart';

/// 消息页:双栏布局 —— 左会话列表(240px)+ 右聊天区。
/// 选中态由 selectedConvProvider 驱动;agentId 从 conversationProvider 查
/// (agent_session 不在列表内,查不到时 null 兜底)。
/// ChatView 按 convId 打 key:切换会话强制重建,列表重新走贴底定位。
class MessagesPage extends ConsumerWidget {
  const MessagesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selectedId = ref.watch(selectedConvProvider);
    final agentId = selectedId == null
        ? null
        : ref
            .watch(conversationProvider)
            .where((c) => c.id == selectedId)
            .firstOrNull
            ?.agent
            ?.id;

    return Scaffold(
      body: Row(
        children: [
          const SizedBox(width: 240, child: ConversationList()),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            key: ValueKey('chat_area_$selectedId'),
            child: selectedId == null
                ? Center(
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
                          '选择一个会话开始聊天',
                          style: TextStyle(
                            fontSize: 14,
                            color: scheme.onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  )
                : ChatView(
                    key: ValueKey('chat_view_$selectedId'),
                    convId: selectedId,
                    agentId: agentId,
                  ),
          ),
        ],
      ),
    );
  }
}
