import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import '../providers/selected_conv_provider.dart';
import 'conversation_list_item.dart';

/// 会话列表列:顶部搜索框(本地按 displayName 过滤)+ 会话列表。
/// 数据源 core conversationProvider(`StateNotifier<List<Conversation>>`,
/// 内部已排序:置顶在前,组内按 lastMessageAt 倒序)。
/// 点击会话仿 app 一级列表路由:多 session 开发型 agent(opencode 类)走
/// [onOpenSessions] 进二级 session 列表;其余写 selectedConvProvider 并触发
/// [onSelected] 回调。
class ConversationList extends ConsumerStatefulWidget {
  final ValueChanged<String>? onSelected;
  final ValueChanged<String>? onOpenSessions;

  const ConversationList({super.key, this.onSelected, this.onOpenSessions});

  @override
  ConsumerState<ConversationList> createState() => _ConversationListState();
}

class _ConversationListState extends ConsumerState<ConversationList> {
  String _query = '';

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
  Widget build(BuildContext context) {
    final list = ref.watch(conversationProvider);
    final selectedId = ref.watch(selectedConvProvider);
    // 摘要预览的 currentUserId(撤回文案「你/对方」分流)。
    final currentUserId = ref.watch(
      authProvider.select((s) => s.user?.id ?? ''),
    );

    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? list
        : list
              .where((c) => c.displayName.toLowerCase().contains(query))
              .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: SizedBox(
            height: 36,
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: '搜索',
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 8,
                  horizontal: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest,
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    query.isEmpty ? '暂无会话' : '无匹配会话',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (_, i) {
                    final c = filtered[i];
                    return ConversationListItem(
                      convId: c.id,
                      name: c.displayName,
                      avatarUrl: c.displayAvatarUrl,
                      agentType: c.agent?.type ?? '',
                      // 多 session agent 行带 session 数第二行(对齐 app)。
                      sessionCount: (c.agent?.isMultiSession ?? false)
                          ? c.sessionCount
                          : -1,
                      pendingCount: (c.agent?.isMultiSession ?? false)
                          ? c.pendingCount
                          : 0,
                      subtitle: c.lastMessagePreview(
                        currentUserId: currentUserId,
                        isGroup: c.isGroup,
                        senderDisplayName: c.lastMessageSenderName,
                      ),
                      time: _formatTime(c.lastMessageAt),
                      unreadCount: c.unreadCount,
                      selected: c.id == selectedId,
                      onTap: () {
                        // 一级列表按 agent 拓扑路由(仿 app):
                        // 多 session(server 注册表 multi_session,含 opencode/dsh)
                        // → 二级 session 列表;其余 → 直接选中开聊。
                        // null(老 server)时 fallback type=='opencode'。
                        if (c.agent?.isMultiSession ?? false) {
                          widget.onOpenSessions?.call(c.agent!.id);
                          return;
                        }
                        ref.read(selectedConvProvider.notifier).state = c.id;
                        widget.onSelected?.call(c.id);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
