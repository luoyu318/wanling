import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:nested_scroll_views/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/user.dart';
import '../pages/agent_list_page.dart';
import '../pages/agent_sessions_page.dart';
import '../pages/messages_page.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart'
    show agentTabUnreadProvider;
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart'
    show totalUnreadProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/theme/app_colors.dart';
import '../widgets/account_sidebar.dart';
import '../widgets/app_action_menu.dart';
import '../widgets/avatar.dart';
import '../widgets/connection_banner.dart';
import '../widgets/local_store_banner.dart';
import '../widgets/feedback/app_dialog.dart';
import '../widgets/nav_tab_bar.dart';
import '../widgets/unread_badge.dart';

/// 主容器：承载动态底部导航 + 全槽平铺 PageView。
///
/// 设计要点：
/// - 全槽平铺：消息/万灵/pinned agent 每槽一独立页，页序 =
///   effectiveNavOrderProvider 序列序（固定项可在任意位），激活态统一为
///   tabId 语义（[_HomePageState._activeTabId]）
/// - 底部 NavTabBar：槽位由序列前缀派生（图标槽/头像槽），pinned 数达阈值
///   出现「更多」槽，点按弹底部抽屉（_showMoreSheet）点选溢出 agent
/// - 长按任意槽进 /nav-edit 编辑页（排序/固定收编编辑页）
/// - 原页 1「我的」的菜单已整段迁入侧滑栏主面板(SidebarProfilePanel)
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// pinned 数达到该值即出现「更多」槽(总槽 = 2 固定 + 2 agent + 更多 = 5)。
  static const int _kOverflowThreshold = 4;

  /// 溢出时可见 agent 数(槽 2/3)。
  static const int _kVisibleWhenOverflow = 2;

  final PageController _pageCtrl = PageController(initialPage: 0);
  String _activeTabId = kNavTabMsg; // 当前激活 tab(任意槽,含溢出 agent)
  bool _sidebarOpen = false; // 左侧切换账号面板开关

  // build 时刷新,手势回调读取(避免回调里重复 watch)
  List<String> _effectiveOrder = const [];
  bool _showMore = false;
  List<String> _visibleSlots = const []; // 序列前缀(固定项+可见 agent)
  List<String> _overflowPinned = const [];

  void _openSidebar() => setState(() => _sidebarOpen = true);
  void _closeSidebar() => setState(() => _sidebarOpen = false);

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  /// 底栏点按:更多槽(=可见槽数)弹抽屉,其余按序列切页。
  void _onNavTap(int slot) {
    if (_showMore && slot == _visibleSlots.length) {
      _showMoreSheet();
      return;
    }
    if (slot < 0 || slot >= _visibleSlots.length) return;
    _switchTab(_visibleSlots[slot]);
  }

  void _switchTab(String tabId) {
    final page = _effectiveOrder.indexOf(tabId);
    if (page < 0) return;
    setState(() => _activeTabId = tabId);
    _jumpToPageSafe(page);
  }

  /// 程序跳页(带动态 children 的 extent 滞后补偿)。
  ///
  /// PageView children 增长后 maxScrollExtent 滞后一帧才就位,期间 jumpToPage
  /// 会被 applyBoundaryConditions clamp 落在旧界内(发出中间页 onPageChanged),
  /// 之后 pixels 自动落位目标页但不发 onPageChanged(官方 PageView 与
  /// NestedPageView 行为一致)。因此跳后下一帧:落点未达则补跳(事件随补跳
  /// 补发);落点已达但激活态被中间页 onPageChanged 污染则直接纠正。
  void _jumpToPageSafe(int page) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_pageCtrl.hasClients || _pageCtrl.page?.round() == page) return;
      _pageCtrl.jumpToPage(page);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_pageCtrl.hasClients) return;
        final landed = _pageCtrl.page?.round();
        final target = (page >= 0 && page < _effectiveOrder.length)
            ? _effectiveOrder[page]
            : null;
        if (landed != page) {
          _pageCtrl.jumpToPage(page);
        } else if (target != null && _activeTabId != target) {
          setState(() => _activeTabId = target);
        }
      });
    });
  }

  /// 跳指定 agent 页(抽屉点选/各处入口);溢出 agent 同样点亮更多槽。
  void _jumpToAgentPage(String agentId) => _switchTab(agentId);

  void _onPageChanged(int page) {
    if (page < 0 || page >= _effectiveOrder.length) return;
    setState(() => _activeTabId = _effectiveOrder[page]);
  }

  /// 底栏选中态:激活 tab 的槽位号;溢出 agent 归更多槽。
  int get _currentNavIndex {
    final idx = _effectiveOrder.indexOf(_activeTabId);
    if (idx < 0) return 0;
    return _showMore && idx >= _visibleSlots.length
        ? _visibleSlots.length
        : idx;
  }

  /// 「更多」底部抽屉：列出溢出 agent（在线态/未读/选中勾），点选切换。
  void _showMoreSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('更多导航',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            for (final id in _overflowPinned)
              Consumer(builder: (_, sheetRef, _) {
                final a = sheetRef.watch(agentByIdProvider(id));
                final unread = sheetRef.watch(agentTabUnreadProvider(id));
                final active = id == _activeTabId;
                return ListTile(
                  leading: Avatar(
                      name: a?.name ?? id, url: a?.avatarUrl, size: 40, radius: 12),
                  title: Text(a?.name ?? id),
                  subtitle: Text(
                    a?.status == AgentStatus.online ? '在线' : '离线',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: unread > 0
                      ? UnreadBadge(count: unread, radius: 8)
                      : (active
                          ? const Icon(Icons.check, color: AppColors.accentGreen)
                          : null),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    _jumpToAgentPage(id);
                  },
                );
              }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// pinned agent id → 底栏槽位数据（名字/在线态/未读）。
  NavAgentTab _toNavAgentTab(String id) {
    final a = ref.watch(agentByIdProvider(id));
    final unread = ref.watch(agentTabUnreadProvider(id));
    return NavAgentTab(
      id: id,
      name: a?.name ?? id,
      avatarUrl: a?.avatarUrl,
      online: a?.status == AgentStatus.online,
      unread: unread,
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalUnread = ref.watch(totalUnreadProvider);
    _effectiveOrder = ref.watch(effectiveNavOrderProvider);
    final pinnedAgents = [
      for (final id in _effectiveOrder) if (!kNavFixedIds.contains(id)) id
    ];
    _showMore = pinnedAgents.length >= _kOverflowThreshold;
    _visibleSlots =
        _effectiveOrder.take(2 + (_showMore ? _kVisibleWhenOverflow : 3)).toList();
    _overflowPinned = _showMore
        ? pinnedAgents.skip(_kVisibleWhenOverflow).toList()
        : [];

    // 收缩守卫:序列变化时按激活 tab 身份判定落点(位置左移跳新位;消失回页 0)。
    // 收缩通知同步于 rebuild 前,prev 即旧列表,据此取激活 tab 新位置。
    ref.listen(effectiveNavOrderProvider, (prev, next) {
      if (prev == null || listEquals(prev, next)) return;
      if (next.contains(_activeTabId)) {
        _jumpToPageSafe(next.indexOf(_activeTabId));
      } else {
        setState(() => _activeTabId = kNavTabMsg);
        _jumpToPageSafe(0);
      }
    });

    return PopScope(
      canPop: !_sidebarOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sidebarOpen) _closeSidebar();
      },
      // Stack 在 Scaffold 外层：遮罩 + 侧滑面板覆盖整个 Scaffold(含底部 tab 栏)
      child: Stack(
        children: [
          Scaffold(
            body: NestedPageView(
              controller: _pageCtrl,
              onPageChanged: _onPageChanged,
              children: [
                for (final id in _effectiveOrder)
                  KeyedSubtree(
                    key: ValueKey('nav-tab-$id'),
                    child: switch (id) {
                      kNavTabMsg => _MsgNavPage(onOpenSidebar: _openSidebar),
                      kNavTabWanling =>
                        _WanlingNavPage(onOpenSidebar: _openSidebar),
                      _ => AgentSessionsPage(agentId: id, embedded: true),
                    },
                  ),
              ],
            ),
            bottomNavigationBar: NavTabBar(
              currentIndex: _currentNavIndex,
              slots: [
                for (final id in _visibleSlots)
                  if (id == kNavTabMsg)
                    NavIconSlot(
                        tabId: id,
                        label: '消息',
                        icon: Icons.chat_bubble_outline,
                        activeIcon: Icons.chat_bubble,
                        badge: totalUnread)
                  else if (id == kNavTabWanling)
                    const NavIconSlot(
                        tabId: kNavTabWanling,
                        label: '万灵',
                        icon: Icons.auto_awesome_outlined,
                        activeIcon: Icons.auto_awesome)
                  else
                    NavAgentSlot(tabId: id, tab: _toNavAgentTab(id)),
              ],
              showMore: _showMore,
              moreTab: _overflowPinned.contains(_activeTabId)
                  ? _toNavAgentTab(_activeTabId)
                  : null,
              onSlotTap: _onNavTap,
              onMoreTap: _showMoreSheet,
              onSlotLongPress: (_) => context.push('/nav-edit'),
            ),
          ),
          // —— 遮罩：覆盖全 Scaffold(含 tab 栏),常驻动画控制透明度 ——
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_sidebarOpen,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                opacity: _sidebarOpen ? 1 : 0,
                child: GestureDetector(
                  onTap: _closeSidebar,
                  child: const ColoredBox(color: Colors.black38),
                ),
              ),
            ),
          ),
          // —— 侧滑面板：包透明 Material 恢复 DefaultTextStyle 继承 ——
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            child: IgnorePointer(
              ignoring: !_sidebarOpen,
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
              offset: _sidebarOpen ? Offset.zero : const Offset(-1, 0),
              // 滑动容器层整体投影(右移 4px + 16 模糊),与旧单层面板层次一致
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x33000000),
                      blurRadius: 16,
                      offset: Offset(4, 0),
                    ),
                  ],
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: AccountSidebar(onClose: _closeSidebar),
                ),
              ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 消息导航页:平铺后的独立 tab 页(原 A 组消息子页)。
class _MsgNavPage extends ConsumerWidget {
  const _MsgNavPage({required this.onOpenSidebar});

  final VoidCallback onOpenSidebar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    return Scaffold(
      appBar: buildHomeAppBar(
        isWanling: false,
        user: user,
        onScan: () => context.push('/pair/scan'),
        onCreateAgent: () => showCreateAgentDialog(context, ref),
        onAvatarTap: onOpenSidebar,
      ),
      body: const Column(
        children: [
          ConnectionBanner(),
          LocalStoreBanner(),
          Expanded(child: MessagesPage()),
        ],
      ),
    );
  }
}

/// 万灵导航页:平铺后的独立 tab 页(原 A 组万灵子页)。
class _WanlingNavPage extends ConsumerWidget {
  const _WanlingNavPage({required this.onOpenSidebar});

  final VoidCallback onOpenSidebar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    return Scaffold(
      appBar: buildHomeAppBar(
        isWanling: true,
        user: user,
        onScan: () => context.push('/pair/scan'),
        onCreateAgent: () => showCreateAgentDialog(context, ref),
        onAvatarTap: onOpenSidebar,
      ),
      body: const AgentListPage(),
    );
  }
}

/// 「新建 Agent」弹窗(消息/万灵页共用,原 _AGroupPage 方法顶层化)。
void showCreateAgentDialog(BuildContext context, WidgetRef ref) {
  final ctrl = TextEditingController();
  showAppDialog(
    context: context,
    title: '创建 Agent',
    content: TextField(
      controller: ctrl,
      autofocus: true,
      decoration: const InputDecoration(labelText: 'Agent 名称'),
    ),
    confirmText: '创建',
    onConfirm: () {
      final name = ctrl.text.trim();
      if (name.isEmpty) return;
      ref.read(agentListProvider.notifier).create(name);
    },
  );
}

/// 构建"消息 / 万灵"首页共享的 AppBar。
///
/// - [isWanling]=false（消息 tab）：靠左头像 + 用户名 + 简介
/// - [isWanling]=true（万灵 tab）：靠左头像 + "万灵"标题（与消息 tab 同尺寸同间距）
///
/// 简介（bio）超过 10 个字（按字素簇计数）会截断加 "…"，null/空则不渲染简介行。
PreferredSizeWidget buildHomeAppBar({
  required bool isWanling,
  required User? user,
  required VoidCallback onScan,
  required VoidCallback onCreateAgent,
  VoidCallback? onAvatarTap,
}) {
  final displayName = user?.displayName ?? '';
  final avatarUrl = user?.avatarUrl;

  final Widget avatar = GestureDetector(
    onTap: onAvatarTap,
    child: Avatar(name: displayName, url: avatarUrl, size: 36, radius: 18),
  );

  final actions = [
    Builder(
      builder: (btnCtx) => IconButton(
        icon: const Icon(Icons.add, color: AppColors.accentGreen),
        tooltip: '更多',
        onPressed: () async {
          final box = btnCtx.findRenderObject() as RenderBox?;
          final pos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
          final selected = await showAppActionMenu(
            btnCtx,
            pos,
            items: const [
              ActionMenuItem(
                value: 'scan',
                label: '扫一扫',
                icon: Icons.qr_code_scanner,
              ),
              ActionMenuItem(
                value: 'create',
                label: '创建 Agent',
                icon: Icons.add_box_outlined,
              ),
            ],
          );
          if (selected == 'scan') {
            onScan();
          } else if (selected == 'create') {
            onCreateAgent();
          }
        },
      ),
    ),
  ];

  if (isWanling) {
    return AppBar(
      centerTitle: false,
      title: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          avatar,
          const SizedBox(width: 10),
          const Text(
            '万灵',
            style: TextStyle(fontWeight: FontWeight.w400),
          ),
        ],
      ),
      actions: actions,
    );
  }

  final bio = truncateBio(user?.bio);
  return AppBar(
    centerTitle: false,
    title: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        avatar,
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
              Text(
                displayName,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                  color: AppColors.textPrimary,
                ),
              ),
              if (bio != null)
                Text(
                  bio,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppColors.textSecondary,
                  ),
                ),
          ],
        ),
      ],
    ),
    actions: actions,
  );
}

/// 简介（bio）截断：>10 字（按字素簇计数）取前 10 字 + "…"，
/// null / 空字符串返回 null（调用方据此跳过渲染简介行）。
String? truncateBio(String? bio) {
  if (bio == null || bio.isEmpty) return null;
  final chars = bio.characters;
  if (chars.length > 10) {
    return '${chars.take(10).join()}…';
  }
  return bio;
}
