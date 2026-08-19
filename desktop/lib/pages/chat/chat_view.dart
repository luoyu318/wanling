import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_desktop/widgets/chat/desktop_input_bar.dart';
import 'chat_app_bar.dart';
import 'chat_message_list.dart';

/// 桌面聊天区:core chatProvider((convId, agentId)) 驱动,
/// ChatAppBar(会话名 + gitBranch 徽标 + 详情开关)+ ChatMessageList +
/// DesktopInputBar(Task 6:工具栏上置 + slash/提及面板 + 文件图片)。
class ChatView extends ConsumerWidget {
  final String convId;
  final String? agentId;

  const ChatView({super.key, required this.convId, this.agentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider((convId: convId, agentId: agentId)));
    final currentUserId = ref.watch(
      authProvider.select((s) => s.user?.id ?? ''),
    );
    final baseUrl = ref.watch(settingsProvider);
    final token = ref.watch(authProvider.select((s) => s.token ?? ''));
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        ChatAppBar(
          title: chat.convTitle ?? '会话',
          gitBranch: chat.sessionMeta?.gitBranch,
        ),
        Expanded(
          child: chat.isInitialLoading
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
              : ChatMessageList(
                  convId: convId,
                  agentId: agentId,
                  currentUserId: currentUserId,
                  baseUrl: baseUrl,
                  token: token,
                ),
        ),
        DesktopInputBar(convId: convId, agentId: agentId),
      ],
    );
  }
}
