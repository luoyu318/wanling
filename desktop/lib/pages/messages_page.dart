import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/selected_conv_provider.dart';
import '../widgets/conversation_list.dart';

/// 消息页:双栏布局 —— 左会话列表(240px)+ 右聊天区占位(Task 5 接聊天页)。
/// 数据与选中态由 core conversationProvider / selectedConvProvider 驱动。
class MessagesPage extends ConsumerWidget {
  const MessagesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final selectedId = ref.watch(selectedConvProvider);
    return Scaffold(
      body: Row(
        children: [
          const SizedBox(width: 240, child: ConversationList()),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Center(
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
                    selectedId == null ? '选择一个会话开始聊天' : '聊天区(Task 5)',
                    style: TextStyle(
                      fontSize: 14,
                      color: scheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
