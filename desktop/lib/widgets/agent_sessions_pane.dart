import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart';
import 'package:wanling_core/providers/agent_provider.dart' show agentByIdProvider;
import 'package:wanling_core/providers/auth_provider.dart';

import '../../providers/selected_conv_provider.dart';
import 'avatar.dart';

/// agent 二级 session 列表面板(消息页/万灵页左栏共用)。
///
/// 仿 app 逻辑:一级列表按 agent.type 路由(supportsMultiSession → 二级)。
/// 数据源 core agentSessionsProvider(agentId)(agent_session 会话不在
/// conversationProvider 内,WS 实时刷新 last_message/unread)。
///
/// 布局(方案 A,视觉稿 /tmp/opencode/session-group-mockup.html):
/// - 返回头:← agent 显示名(列表未加载时兜底「会话列表」)
/// - session 按 directory 项目分组:📂 basename 组头(计数胶囊 + 折叠箭头,
///   点击折叠/展开),组内保留头像 tile(信息密度与一级列表一致)
/// - 无 directory 的会话归「其他」组(📁)
/// - 组序按组内最新会话时间倒序(沿用 provider 排序的首现顺序)
/// - 选中态对齐一级列表新样式:品牌绿底 + 白字
class AgentSessionsPane extends ConsumerStatefulWidget {
  final String agentId;
  final VoidCallback onBack;
  final void Function(String convId, String agentId) onOpenSession;

  /// 选中会话 id 覆盖值:万灵 tab 传 selectedWanlingConvProvider 的值
  /// (双 tab 选中态隔离);null = 内部 watch 消息 tab 的
  /// selectedConvProvider(消息 tab 调用方默认行为)。
  final String? selectedConvId;

  const AgentSessionsPane({
    super.key,
    required this.agentId,
    required this.onBack,
    required this.onOpenSession,
    this.selectedConvId,
  });

  @override
  ConsumerState<AgentSessionsPane> createState() => _AgentSessionsPaneState();
}

class _AgentSessionsPaneState extends ConsumerState<AgentSessionsPane> {
  /// 已折叠组名(directory basename)。
  final Set<String> _collapsed = {};

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

  /// 分组名:directory 取 basename,空/缺失归「其他」。
  static String _groupName(Conversation c) {
    final dir = c.directory;
    if (dir == null || dir.isEmpty) return '其他';
    final base = dir.replaceAll('\\', '/').split('/').last;
    return base.isEmpty ? '其他' : base;
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(agentSessionsProvider(widget.agentId));
    final scheme = Theme.of(context).colorScheme;
    final currentUserId = ref.watch(
      authProvider.select((s) => s.user?.id ?? ''),
    );
    // 选中高亮:外部覆盖值优先(万灵 tab 独立选中),否则消息 tab provider。
    final selectedId =
        widget.selectedConvId ?? ref.watch(selectedConvProvider);
    final agent = ref.watch(agentByIdProvider(widget.agentId));

    return Column(
      children: [
        // 返回头:返回一级列表,文案为 agent 显示名。
        InkWell(
          key: const ValueKey('agent_sessions_back'),
          onTap: widget.onBack,
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
                Expanded(
                  child: Text(
                    agent?.name ?? '会话列表',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurface.withValues(alpha: 0.6),
                    ),
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
                  : _buildGroupedList(
                      sessions: sessions,
                      scheme: scheme,
                      currentUserId: currentUserId,
                      selectedId: selectedId,
                    ),
        ),
      ],
    );
  }

  Widget _buildGroupedList({
    required List<Conversation> sessions,
    required ColorScheme scheme,
    required String currentUserId,
    required String? selectedId,
  }) {
    // LinkedHashMap 保序:组序 = 组内最新会话的首现顺序(provider 已按
    // lastMessageAt 倒序),「其他」组不置底特殊处理,同样按时间归位。
    final groups = <String, List<Conversation>>{};
    for (final s in sessions) {
      groups.putIfAbsent(_groupName(s), () => []).add(s);
    }

    return ListView(
      key: ValueKey('agent_sessions_${widget.agentId}'),
      children: [
        for (final entry in groups.entries) ...[
          _GroupHeader(
            name: entry.key,
            count: entry.value.length,
            isOther: entry.key == '其他',
            collapsed: _collapsed.contains(entry.key),
            onToggle: () => setState(() {
              _collapsed.contains(entry.key)
                  ? _collapsed.remove(entry.key)
                  : _collapsed.add(entry.key);
            }),
          ),
          if (!_collapsed.contains(entry.key))
            for (final s in entry.value)
              _SessionTile(
                conv: s,
                selected: s.id == selectedId,
                onTap: () => widget.onOpenSession(s.id, widget.agentId),
                time: _formatTime(s.lastMessageAt),
                currentUserId: currentUserId,
              ),
        ],
      ],
    );
  }
}

/// 组头:folder 图标 + 项目名 + 计数胶囊 + 折叠箭头(收起时逆时针转 90°)。
class _GroupHeader extends StatelessWidget {
  final String name;
  final int count;
  final bool isOther;
  final bool collapsed;
  final VoidCallback onToggle;

  const _GroupHeader({
    required this.name,
    required this.count,
    required this.isOther,
    required this.collapsed,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 12, 5),
        child: Row(
          children: [
            Icon(
              isOther ? Icons.folder_open_outlined : Icons.folder_outlined,
              size: 14,
              color: scheme.onSurface.withValues(alpha: 0.5),
            ),
            const SizedBox(width: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10,
                  color: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
            const Spacer(),
            Transform.rotate(
              angle: collapsed ? -math.pi / 2 : 0,
              child: Icon(
                Icons.expand_more,
                size: 14,
                color: scheme.onSurface.withValues(alpha: 0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// session 列表项:头像 + 名称 + 摘要 + 时间(未读 badge 在头像右上)。
/// 选中态柔和主色 tint 底 + onSurface 文字,对齐一级列表样式。
class _SessionTile extends StatelessWidget {
  final Conversation conv;
  final bool selected;
  final String time;
  final String currentUserId;
  final VoidCallback onTap;

  const _SessionTile({
    required this.conv,
    required this.selected,
    required this.time,
    required this.currentUserId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 2),
      child: Container(
        key: ValueKey('agent_session_${conv.id}'),
        decoration: BoxDecoration(
          color: selected ? scheme.primary.withValues(alpha: 0.10) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                Avatar(
                  name: conv.displayName,
                  url: conv.displayAvatarUrl,
                  size: 34,
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
                        style: TextStyle(
                          fontSize: 13.5,
                          color: scheme.onSurface,
                          fontWeight: selected ? FontWeight.w600 : null,
                        ),
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
                          color: scheme.onSurface.withValues(alpha: 0.5),
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
        ),
      ),
    );
  }
}
