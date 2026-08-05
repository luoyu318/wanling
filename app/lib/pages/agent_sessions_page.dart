import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/agent.dart' hide AgentStatus;
import '../theme/app_colors.dart';
import '../models/conversation.dart';
import '../providers/agent_provider.dart' show agentByIdProvider;
import '../providers/agent_sessions_provider.dart';
import '../providers/agent_status_provider.dart';
import '../providers/auth_provider.dart' show authProvider;
import '../providers/saved_logins_provider.dart';
import '../router_helpers.dart';
import '../utils/directory_utils.dart';
import '../utils/snackbar.dart';
import '../widgets/agent_badge.dart';
import '../widgets/avatar.dart';
import '../widgets/conv_action_menu.dart';
import '../widgets/chat/shimmer_text.dart';
import '../widgets/chat/three_body_indicator.dart';
import '../widgets/directory_menu_badge.dart';
import '../widgets/directory_panel.dart';
import '../widgets/directory_picker_sheet.dart';

class AgentSessionsPage extends ConsumerStatefulWidget {
  final String agentId;
  const AgentSessionsPage({super.key, required this.agentId});

  @override
  ConsumerState<AgentSessionsPage> createState() => _AgentSessionsPageState();
}

class _AgentSessionsPageState extends ConsumerState<AgentSessionsPage> {
  static const _noSelection = '\u0000__no_selection__';
  static const _prefsUncategorized = '__uncategorized__';

  bool _creating = false;
  String? _selectedDirectory;
  bool _directorySelected = false;
  List<String> _directoryOrder = [];
  List<Conversation> _lastSessions = const [];

  @override
  void initState() {
    super.initState();
    _loadDirectoryOrder();
    _loadSelectedDirectory();
  }

  void _loadDirectoryOrder() {
    final prefs = ref.read(sharedPrefsProvider);
    final order = prefs.getStringList('dir_order_${widget.agentId}');
    if (order != null) {
      _directoryOrder = order;
    }
  }

  Future<void> _saveDirectoryOrder() async {
    final prefs = ref.read(sharedPrefsProvider);
    await prefs.setStringList('dir_order_${widget.agentId}', _directoryOrder);
  }

  Future<void> _loadSelectedDirectory() async {
    final prefs = ref.read(sharedPrefsProvider);
    final saved = prefs.getString('dir_selected_${widget.agentId}');
    if (saved != null && saved.isNotEmpty && mounted) {
      setState(() {
        _selectedDirectory =
            saved == _prefsUncategorized ? null : saved;
        _directorySelected = true;
      });
    }
  }

  Future<void> _saveSelectedDirectory() async {
    final prefs = ref.read(sharedPrefsProvider);
    if (!_directorySelected) {
      await prefs.remove('dir_selected_${widget.agentId}');
      return;
    }
    final value = _selectedDirectory ?? _prefsUncategorized;
    await prefs.setString('dir_selected_${widget.agentId}', value);
  }
  void _onDirReorder(int oldIndex, int newIndex) {
    HapticFeedback.selectionClick();
    setState(() {
      // 同步当前 sessions 派生 order,避免 _directoryOrder 与实际 list 脱节。
      // _lastSessions 由最近一次 build 写入(只缓存引用,不产生 build 期副作用)。
      final grouped = groupByDirectory(_lastSessions);
      final derived =
          buildDirectoryList(grouped, _directoryOrder, const {});
      _directoryOrder = derived
          .where((d) => d.path != null)
          .map((d) => d.path!)
          .toList();
      if (newIndex > oldIndex) newIndex -= 1;
      if (newIndex == oldIndex) return;
      if (oldIndex >= _directoryOrder.length ||
          newIndex >= _directoryOrder.length) {
        return;
      }
      final item = _directoryOrder.removeAt(oldIndex);
      _directoryOrder.insert(newIndex, item);
    });
    unawaited(_saveDirectoryOrder());
  }

  Future<void> _createSession() async {
    if (_creating) return;
    final result = await showDirectoryPickerSheet(
      context,
      agentId: widget.agentId,
      defaultDirectory: _selectedDirectory,
    );
    if (!mounted) return;
    if (result == null || result.cancelled) return;
    setState(() => _creating = true);
    final notifier = ref.read(agentSessionsProvider(widget.agentId).notifier);
    try {
      final agent = ref.read(agentByIdProvider(widget.agentId));
      final convId = await notifier.createSession(
        widget.agentId,
        title: agent?.name,
        directory: result.directory,
      );
      if (!mounted) return;
      unawaited(context.push(chatRoute(convId, widget.agentId)));
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, '创建会话失败: $e', type: SnackBarType.error);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  List<DirectoryInfo> _deriveDirectories(
      List<Conversation> sessions, Map<String, AgentStatus> statusMap) {
    _lastSessions = sessions;
    final grouped = groupByDirectory(sessions);
    return buildDirectoryList(grouped, _directoryOrder, statusMap);
  }

  List<Conversation> _filterSessions(List<Conversation> sessions) {
    if (!_directorySelected) return sessions;
    return sessions.where((s) => s.directory == _selectedDirectory).toList();
  }

  @override
  Widget build(BuildContext context) {
    final agent = ref.watch(agentByIdProvider(widget.agentId));
    final currentUserId = ref.watch(authProvider).user?.id ?? '';
    final notifier = ref.read(agentSessionsProvider(widget.agentId).notifier);
    final list = ref.watch(agentSessionsProvider(widget.agentId));

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 600;
        return isWide
            ? _buildTabletLayout(agent, list, currentUserId, notifier)
            : _buildPhoneLayout(agent, list, currentUserId, notifier);
      },
    );
  }

  Scaffold _buildPhoneLayout(
    Agent? agent,
    List<Conversation>? list,
    String currentUserId,
    AgentSessionsNotifier notifier,
  ) {
    final statusMap = ref.watch(agentStatusProvider);
    List<DirectoryInfo> dirs = const [];
    List<Conversation> filtered = const [];
    if (list != null) {
      dirs = _deriveDirectories(list, statusMap);
      filtered = _filterSessions(list);
    }
    final effectiveSelected =
        _directorySelected ? _selectedDirectory : _noSelection;
    // 目录切换按钮角标:聚合全部目录的未读/待处理
    final otherUnread = dirs.fold(0, (sum, d) => sum + d.unreadCount);
    final otherPending = dirs.fold(0, (sum, d) => sum + d.pendingCount);

    return Scaffold(
      drawerEdgeDragWidth: MediaQuery.sizeOf(context).width,
      appBar: AppBar(
        leading: list != null && list.isNotEmpty
            ? Builder(
                builder: (context) => Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.menu),
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        Scaffold.of(context).openDrawer();
                      },
                    ),
                    ...DirectoryMenuBadge.build(
                      unread: otherUnread,
                      pending: otherPending,
                    ),
                  ],
                ),
              )
            : null,
        title: agent == null
            ? const Text('会话')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          agent.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                      const SizedBox(width: 4),
                      AgentBadge(type: agent.type, elevated: true),
                    ],
                  ),
                  if (_selectedDirectory != null)
                    Text(
                      pathLastTwoSegments(_selectedDirectory),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF888888),
                      ),
                    ),
                ],
              ),
        actions: [
          IconButton(
            icon: _creating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            onPressed: _creating ? null : _createSession,
          ),
        ],
      ),
      drawer: list == null || list.isEmpty
          ? null
          : Drawer(
              child: ColoredBox(
                color: Colors.white,
                child: SafeArea(
                  child: DirectoryPanel(
                    agent: agent == null
                        ? null
                        : AgentSummary(
                            id: agent.id,
                            name: agent.name,
                            avatarUrl: agent.avatarUrl,
                            status: agent.status,
                            type: agent.type,
                            bio: agent.bio,
                          ),
                    directories: dirs,
                    selectedPath: effectiveSelected,
                    showHeader: false,
                    onSelected: (path) {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _selectedDirectory = path;
                        _directorySelected = true;
                      });
                      Navigator.of(context).pop();
                      unawaited(_saveSelectedDirectory());
                    },
                    onReorder: _onDirReorder,
                    onNewSession: _createSession,
                  ),
                ),
              ),
            ),
      body: _buildBody(context, list, filtered, currentUserId, notifier),
    );
  }

  Scaffold _buildTabletLayout(
    Agent? agent,
    List<Conversation>? list,
    String currentUserId,
    AgentSessionsNotifier notifier,
  ) {
    final statusMap = ref.watch(agentStatusProvider);
    final dirs = list == null ? <DirectoryInfo>[] : _deriveDirectories(list, statusMap);
    final filtered = list == null ? <Conversation>[] : _filterSessions(list);
    final effectiveSelected =
        _directorySelected ? _selectedDirectory : _noSelection;

    return Scaffold(
      appBar: AppBar(
        title: agent == null
            ? const Text('会话')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          agent.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                      const SizedBox(width: 4),
                      AgentBadge(type: agent.type, elevated: true),
                    ],
                  ),
                  if (_selectedDirectory != null)
                    Text(
                      pathLastTwoSegments(_selectedDirectory),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF888888),
                      ),
                    ),
                ],
              ),
        actions: [
          TextButton.icon(
            onPressed: _creating ? null : _createSession,
            icon: _creating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add, size: 18),
            label: const Text('新建会话'),
          ),
        ],
      ),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : Row(
              children: [
                SizedBox(
                  width: 220,
                  child: DirectoryPanel(
                    agent: agent == null
                        ? null
                        : AgentSummary(
                            id: agent.id,
                            name: agent.name,
                            avatarUrl: agent.avatarUrl,
                            status: agent.status,
                            type: agent.type,
                            bio: agent.bio,
                          ),
                    directories: dirs,
                    selectedPath: effectiveSelected,
                    showHeader: true,
                    onSelected: (path) {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _selectedDirectory = path;
                        _directorySelected = true;
                      });
                      unawaited(_saveSelectedDirectory());
                    },
                    onReorder: _onDirReorder,
                    onNewSession: _createSession,
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _buildBody(context, list, filtered, currentUserId, notifier),
                ),
              ],
            ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    List<Conversation>? list,
    List<Conversation> filtered,
    String currentUserId,
    AgentSessionsNotifier notifier,
  ) {
    if (list == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (list.isEmpty) {
      return Center(
        child: RefreshIndicator(
          color: AppColors.accentGreen,
          onRefresh: notifier.load,
          child: ListView(
            children: const [
              SizedBox(height: 200),
              Center(child: Text('暂无会话')),
            ],
          ),
        ),
      );
    }

    if (_directorySelected && filtered.isEmpty) {
      return const Center(child: Text('该目录下暂无会话'));
    }

    return RefreshIndicator(
      color: AppColors.accentGreen,
      onRefresh: notifier.load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: filtered.length,
        itemBuilder: (_, i) {
          final c = filtered[i];
          return _SessionTile(
            conv: c,
            currentUserId: currentUserId,
            onTap: () => context.push(chatRoute(c.id, widget.agentId)),
            onLongPressStart: (details) => showConvActionMenu(
              context,
              details.globalPosition,
              isPinned: c.isPinned,
              onPinToggle: () =>
                  c.isPinned ? notifier.unpin(c.id) : notifier.pin(c.id),
              onHide: () => notifier.hide(c.id),
            ),
          );
        },
      ),
    );
  }
}

class _SessionTile extends ConsumerStatefulWidget {
  final Conversation conv;
  final String currentUserId;
  final VoidCallback onTap;
  final void Function(LongPressStartDetails details) onLongPressStart;

  const _SessionTile({
    required this.conv,
    required this.currentUserId,
    required this.onTap,
    required this.onLongPressStart,
  });

  @override
  ConsumerState<_SessionTile> createState() => _SessionTileState();
}

class _SessionTileState extends ConsumerState<_SessionTile> {
  bool _isPressed = false;

  void _setPressed(bool v) {
    if (_isPressed == v) return;
    setState(() => _isPressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.conv;
    final agentStatus = ref.watch(
      agentStatusProvider.select((s) => s[widget.conv.id]),
    );
    final tileBg = _isPressed
        ? (c.isPinned ? const Color(0xFFD6D6D6) : const Color(0xFFEDEDED))
        : (c.isPinned ? const Color(0xFFEDEDED) : Colors.white);

    final dividerColor = c.isPinned
        ? const Color(0xFFD6D6D6)
        : const Color(0xFFE4E4E4);
    final dividerBg = c.isPinned ? const Color(0xFFEDEDED) : Colors.white;

    return Listener(
      onPointerDown: (_) => _setPressed(true),
      onPointerUp: (_) => _setPressed(false),
      onPointerCancel: (_) => _setPressed(false),
      child: GestureDetector(
        onLongPressStart: (details) {
          HapticFeedback.selectionClick();
          widget.onLongPressStart(details);
        },
        child: InkWell(
          onTap: widget.onTap,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Column(
            children: [
              Container(
                color: tileBg,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Avatar(
                      name: c.displayName,
                      url: c.displayAvatarUrl.isNotEmpty
                          ? c.displayAvatarUrl
                          : null,
                      size: 40,
                      radius: 20,
                      unreadCount: c.unreadCount,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            c.displayName,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 17,
                              color: Color(0xFF111111),
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                          const SizedBox(height: 2),
                          if (c.pendingCount > 0)
                            Text(
                              '待处理 ${c.pendingCount} 项',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFFE53935),
                                fontWeight: FontWeight.w300,
                              ),
                            )
                          else if (agentStatus != null &&
                              agentStatus.type == AgentStatusType.busy)
                            const ShimmerText(
                              text: '灵光涌动...',
                              baseColor: Color(0xFF07C160),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w300,
                              ),
                            )
                          else if (agentStatus != null &&
                              agentStatus.type == AgentStatusType.retry)
                            ShimmerText(
                              text: '重试中(第 ${agentStatus.attempt} 次)...',
                              baseColor: const Color(0xFFE53935),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w300,
                              ),
                            )
                          else
                            Text(
                              (c.lastUserMessageContent?.isNotEmpty ?? false)
                                  ? '${c.lastUserMessageContent!} · ${_formatCreationDate(c.createdAt)}'
                                  : _formatCreationDate(c.createdAt),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF999999),
                                fontWeight: FontWeight.w300,
                              ),
                            ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatTime(c.lastMessageAt),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFFB0B0B0),
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                        if (agentStatus != null)
                          const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: SizedBox(
                              width: 32,
                              height: 16,
                              child: ThreeBodyIndicator(),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Container(
                height: 0.5,
                color: dividerBg,
                child: Container(
                  margin: const EdgeInsets.only(left: 70),
                  color: dividerColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatTime(DateTime dt) {
  final now = DateTime.now();
  final diff = now.difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  if (diff.inDays < 1) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
  if (diff.inDays < 7) return '${diff.inDays}天前';
  return '${dt.month}/${dt.day}';
}

String _formatCreationDate(DateTime dt) {
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  return '$m-$d 创建';
}
