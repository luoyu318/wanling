import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:nested_scroll_views/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/models/user.dart';
import '../pages/agent_list_page.dart';
import '../pages/agent_sessions_page.dart';
import '../pages/messages_page.dart';
import '../pages/mini_program_list_page.dart';
import '../router_helpers.dart' show chatRoute, sessionsRoute;
import '../services/mini_program_launcher.dart';
import '../widgets/mini_program_pull_panel.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart'
    show agentTabUnreadProvider;
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart'
    show conversationProvider, convByIdProvider, totalUnreadProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/providers/mini_programs_provider.dart';
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
  // 底栏切换只靠点按导航槽;PageView 禁用拖动手势(避免与二级页横滑手势冲突)。
  static const _kPageViewPhysics = NeverScrollableScrollPhysics();

  /// PageView 页序列:导航序列去掉会话槽与小程序槽(两者都是跳转入口,不占平铺页)。
  List<String> get _pages => [
        for (final id in _effectiveOrder)
          if (!isConvNavId(id) && !isMpNavId(id)) id
      ];

  final PageController _pageCtrl = PageController(initialPage: 0);
  String _activeTabId = kNavTabMsg; // 当前激活 tab(任意槽,含溢出 agent)
  bool _sidebarOpen = false; // 左侧切换账号面板开关
  int _jumpEpoch = 0; // 跳页纪元:新指令使旧补跳链失效,防并发链互相拉扯

  /// 消息页小程序面板完成态:底栏按它收缩(高度 64→0),由 _MsgNavPage 的
  /// MiniProgramPullScope 置位。
  final ValueNotifier<bool> _msgPanelOpen = ValueNotifier(false);

  // build 时刷新,手势回调读取(避免回调里重复 watch)
  List<String> _effectiveOrder = const [];
  bool _showMore = false;
  bool _moreSheetOpen = false; // 「更多」抽屉开关(Stack 层,不遮底栏)
  List<String> _visibleSlots = const []; // 可见槽位(序列前缀,固定项/agent 混合)
  List<String> _overflowItems = const []; // 溢出项(含固定项,进更多抽屉可达)

  void _openSidebar() => setState(() => _sidebarOpen = true);
  void _closeSidebar() => setState(() => _sidebarOpen = false);

  @override
  void dispose() {
    _pageCtrl.dispose();
    _msgPanelOpen.dispose();
    super.dispose();
  }

  /// 底栏点按:更多槽(=可见槽数)弹抽屉,其余按序列切页;点按同时收起抽屉。
  void _onNavTap(int slot) {
    if (_moreSheetOpen) _closeMoreSheet();
    if (_showMore && slot == _visibleSlots.length) {
      _openMoreSheet();
      return;
    }
    if (slot < 0 || slot >= _visibleSlots.length) return;
    _switchTab(_visibleSlots[slot]);
  }

  void _switchTab(String tabId) {
    if (!_effectiveOrder.contains(tabId)) return;
    // 会话槽:按消息列表项同款逻辑跳转(multi_session 聚合 → sessions 页,
    // 其余 → 聊天页),不改变 tab 激活态。
    final convId = navConvIdOf(tabId);
    if (convId != null) {
      final conv = ref.read(convByIdProvider(convId));
      if (conv == null) return;
      if (conv.agent?.isMultiSession ?? false) {
        context.push(sessionsRoute(conv.agent!.id));
      } else {
        context.push(chatRoute(conv.id, conv.agent?.id));
      }
      return;
    }
    // 小程序槽:push 容器页,不改变 tab 激活态(conv 槽同构)。
    final appid = navMpAppidOf(tabId);
    if (appid != null) {
      context.push('/mini-program/$appid');
      return;
    }
    setState(() => _activeTabId = tabId);
    _jumpToPageSafe(tabId);
  }

  /// 程序跳页(带动态 children 的 extent 滞后补偿)。
  ///
  /// PageView children 增长后 maxScrollExtent 滞后一帧才就位,期间 jumpToPage
  /// 会被 clamp 落在旧界内:发出中间页 onPageChanged(污染激活态),pixels 随后
  /// 静默落位目标页且不再发 onPageChanged。故逐帧复核:落点未达则续跳;已达但
  /// 激活态被污染则纠正。捕获 tabId 而非下标,序列再变时按身份重算落点。
  void _jumpToPageSafe(String tabId) {
    final epoch = ++_jumpEpoch;
    void jump() {
      if (!mounted || !_pageCtrl.hasClients || epoch != _jumpEpoch) return;
      final page = _pages.indexOf(tabId);
      if (page < 0) return;
      if (_pageCtrl.page?.round() != page) {
        _pageCtrl.jumpToPage(page);
        WidgetsBinding.instance.addPostFrameCallback((_) => jump());
      } else if (_activeTabId != tabId) {
        setState(() => _activeTabId = tabId);
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => jump());
  }

  void _onPageChanged(int page) {
    if (page < 0 || page >= _pages.length) return;
    final id = _pages[page];
    setState(() => _activeTabId = id);
    // 切进小程序 tab 时静默刷新列表:provider 被底栏槽等常驻 watch,
    // autoDispose 名存实亡,切回命中缓存直接回旧数据;invalidate 后由
    // 列表页 skipLoadingOnRefresh 保旧数据换新,不闪 loading。
    if (id == kNavTabMiniProgram) {
      ref.invalidate(miniProgramsProvider);
    }
  }

  /// 底栏选中态:激活 tab 在可见槽中的位置;溢出 agent 归更多槽。
  int get _currentNavIndex {
    final idx = _visibleSlots.indexOf(_activeTabId);
    if (idx >= 0) return idx;
    return _showMore ? _visibleSlots.length : 0;
  }

  /// 「更多」抽屉:state 驱动的 Stack 层,遮罩只盖导航条上方(导航条保持
  /// 可见可点,对齐主流 IM)。抽屉弹出时长按底栏项 → 进底栏编辑页。
  void _openMoreSheet() => setState(() => _moreSheetOpen = true);

  void _closeMoreSheet() => setState(() => _moreSheetOpen = false);

  /// 底栏总高(NavTabBar = SafeArea 底部 + 56)。
  double get _navBarHeight =>
      56 + MediaQuery.of(context).padding.bottom;

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

  /// 会话槽 id → 底栏槽位数据(名字/头像/未读,与消息列表同源)。
  /// 在线态取会话关联 agent 的实时状态(agent 槽同源,WS 上下线事件联动);
  /// 好友/群会话无 agent,恒 false 不渲染绿点。
  NavConvTab _toNavConvTab(String id) {
    final convId = navConvIdOf(id)!;
    final conv = ref.watch(convByIdProvider(convId));
    final agentId = conv?.agent?.id;
    final agent = agentId == null ? null : ref.watch(agentByIdProvider(agentId));
    return NavConvTab(
      id: convId,
      name: conv?.displayName ?? convId,
      avatarUrl: conv?.displayAvatarUrl,
      unread: conv?.unreadCount ?? 0,
      online: agent?.status == AgentStatus.online,
    );
  }

  /// 小程序槽 id → 底栏槽位数据(名称/icon,iconUrl 空走 Avatar 首字 fallback)。
  NavMpTab _toNavMpTab(String id) {
    final appid = navMpAppidOf(id)!;
    final list = ref.watch(miniProgramsProvider).valueOrNull;
    MiniProgramInfo? mp;
    for (final m in list ?? const <MiniProgramInfo>[]) {
      if (m.appid == appid) {
        mp = m;
        break;
      }
    }
    final url = mp?.iconUrlFor(ref.watch(apiProvider).baseUrl);
    return NavMpTab(
      id: appid,
      name: mp?.name ?? appid,
      iconUrl: (url == null || url.isEmpty) ? null : url,
    );
  }

  @override
  Widget build(BuildContext context) {
    final totalUnread = ref.watch(totalUnreadProvider);
    _effectiveOrder = ref.watch(effectiveNavOrderProvider);
    final storedVisible = ref.watch(navVisibleCountProvider);
    // 可见槽数由用户在编辑页拖项进/出「更多」决定(存 SP);未设置时自动:
    // 总项 ≤4 全可见,否则可见 4。最少保留 1 个导航元素在底栏。
    final visibleCount =
        resolveVisibleCount(storedVisible, _effectiveOrder.length);
    _showMore = _effectiveOrder.length > visibleCount;
    _visibleSlots = _effectiveOrder.take(visibleCount).toList();
    _overflowItems = _showMore
        ? _effectiveOrder.skip(visibleCount).toList()
        : [];

    // 收缩守卫:序列变化时按激活 tab 身份判定落点(位置左移跳新位;消失回页 0)。
    // 收缩通知同步于 rebuild 前,prev 即旧列表,据此取激活 tab 新位置。
    ref.listen(effectiveNavOrderProvider, (prev, next) {
      if (prev == null || listEquals(prev, next)) return;
      if (next.contains(_activeTabId)) {
        _jumpToPageSafe(_activeTabId);
      } else {
        setState(() => _activeTabId = kNavTabMsg);
        _jumpToPageSafe(kNavTabMsg);
      }
    });

    return PopScope(
      canPop: !_sidebarOpen && !_moreSheetOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_sidebarOpen) {
          _closeSidebar();
        } else if (_moreSheetOpen) {
          _closeMoreSheet();
        }
      },
      // Stack 在 Scaffold 外层：遮罩 + 侧滑面板覆盖整个 Scaffold(含底部 tab 栏)
      child: Stack(
        children: [
          Scaffold(
            body: NestedPageView(
              controller: _pageCtrl,
              physics: _kPageViewPhysics,
              onPageChanged: _onPageChanged,
              children: [
                for (final id in _pages)
                  KeyedSubtree(
                    key: ValueKey('nav-tab-$id'),
                    child: switch (id) {
                      kNavTabMsg => _MsgNavPage(
                        onOpenSidebar: _openSidebar,
                        panelOpenNotifier: _msgPanelOpen,
                      ),
                      kNavTabWanling =>
                        _WanlingNavPage(onOpenSidebar: _openSidebar),
                      kNavTabMiniProgram =>
                        const MiniProgramListPage(embedded: true),
                      _ => AgentSessionsPage(agentId: id, embedded: true),
                    },
                  ),
              ],
            ),
            // 底栏随消息页面板完成态收缩(高度 64→0,mockup 对齐);Clip 防止
            // 收缩过程内容溢出。_navBarHeight = NavTabBar 自然高(SafeArea 底部
            // + 56),非完成态与原布局一致。
            bottomNavigationBar: ValueListenableBuilder<bool>(
              valueListenable: _msgPanelOpen,
              builder: (context, panelOpen, _) => AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
                height: panelOpen ? 0 : _navBarHeight,
                clipBehavior: Clip.hardEdge,
                decoration: const BoxDecoration(),
                child: NavTabBar(
                  currentIndex: _currentNavIndex,
                  slots: [
                    for (final id in _visibleSlots)
                      if (id == kNavTabMsg)
                        NavIconSlot(
                            tabId: id,
                            label: kNavTabMsgLabel,
                            // 选中态用镂空 outline、未选中用 filled(用户偏好,与常规相反)
                            icon: Icons.chat_bubble,
                            activeIcon: Icons.chat_bubble_outline,
                            badge: totalUnread)
                      else if (id == kNavTabWanling)
                        const NavIconSlot(
                            tabId: kNavTabWanling,
                            label: kNavTabWanlingLabel,
                            icon: Icons.auto_awesome,
                            activeIcon: Icons.auto_awesome_outlined)
                      else if (id == kNavTabMiniProgram)
                        const NavIconSlot(
                            tabId: kNavTabMiniProgram,
                            label: kNavTabMiniProgramLabel,
                            icon: Icons.grid_view,
                            activeIcon: Icons.grid_view_outlined)
                      else if (isConvNavId(id))
                        NavConvSlot(tabId: id, tab: _toNavConvTab(id))
                      else if (isMpNavId(id))
                        NavMpSlot(tabId: id, tab: _toNavMpTab(id))
                      else
                        NavAgentSlot(tabId: id, tab: _toNavAgentTab(id)),
                  ],
                  showMore: _showMore,
                  moreTab: _overflowItems.contains(_activeTabId) &&
                          !kNavFixedIds.contains(_activeTabId)
                      ? _toNavAgentTab(_activeTabId)
                      : null,
                  onSlotTap: _onNavTap,
                  onMoreTap: _openMoreSheet,
                  // 编辑入口:有更多槽时须先弹抽屉再长按(避免误触);无更多槽
                  // (项≤4,抽屉不可达)保留长按直进兜底。
                  onSlotLongPress: (_) {
                    if (_showMore && !_moreSheetOpen) return;
                    if (_moreSheetOpen) _closeMoreSheet();
                    context.push('/nav-edit');
                  },
                ),
              ),
            ),
          ),
          // —— 「更多」抽屉层:遮罩+面板都在导航条上方,导航条不被遮挡可点 ——
          if (_moreSheetOpen) ...[
            Positioned.fill(
              bottom: _navBarHeight,
              child: GestureDetector(
                onTap: _closeMoreSheet,
                child: const ColoredBox(color: Colors.black38),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: _navBarHeight,
              child: Material(
                color: Colors.transparent,
                child: _MoreSheetPanel(
                  overflowItems: _overflowItems,
                  activeTabId: _activeTabId,
                  onClose: _closeMoreSheet,
                  onEdit: () {
                    _closeMoreSheet();
                    context.push('/nav-edit');
                  },
                  onPickItem: (id) {
                    _closeMoreSheet();
                    _switchTab(id);
                  },
                  onLongPressItem: (id) {
                    _closeMoreSheet();
                    context.push('/nav-edit');
                  },
                ),
              ),
            ),
          ],
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

/// 「更多」抽屉面板:溢出项(含消息/万灵)4 列网格 + 右上「编辑」。
/// 由 HomePage 以 Stack 层承载(导航条上方),不再用 modal route。
class _MoreSheetPanel extends ConsumerWidget {
  const _MoreSheetPanel({
    required this.overflowItems,
    required this.activeTabId,
    required this.onClose,
    required this.onEdit,
    required this.onPickItem,
    required this.onLongPressItem,
  });

  final List<String> overflowItems;
  final String activeTabId;
  final VoidCallback onClose;
  final VoidCallback onEdit;
  final ValueChanged<String> onPickItem;
  final ValueChanged<String> onLongPressItem;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF7F7F7),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Text('更多',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  TextButton(
                    onPressed: onEdit,
                    child: const Text('编辑',
                        style: TextStyle(color: Color(0xFF3370FF))),
                  ),
                ],
              ),
            ),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              crossAxisCount: 4,
              mainAxisSpacing: 16,
              crossAxisSpacing: 8,
              childAspectRatio: 0.72,
              children: [
                for (final id in overflowItems)
                  if (kNavFixedIds.contains(id))
                    _MoreSheetIconItem(
                      key: ValueKey('more-$id'),
                      tabId: id,
                      active: id == activeTabId,
                      onTap: () => onPickItem(id),
                      onLongPress: () => onLongPressItem(id),
                    )
                  else if (isConvNavId(id))
                    _MoreSheetConvItem(
                      key: ValueKey('more-$id'),
                      convId: id,
                      active: id == activeTabId,
                      onTap: () => onPickItem(id),
                      onLongPress: () => onLongPressItem(id),
                    )
                  else if (isMpNavId(id))
                    _MoreSheetMpItem(
                      key: ValueKey('more-$id'),
                      mpId: id,
                      active: id == activeTabId,
                      onTap: () => onPickItem(id),
                      onLongPress: () => onLongPressItem(id),
                    )
                  else
                    _MoreSheetItem(
                      key: ValueKey('more-$id'),
                      agentId: id,
                      active: id == activeTabId,
                      onTap: () => onPickItem(id),
                      onLongPress: () => onLongPressItem(id),
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 抽屉网格项(固定项):白圆角图标方块+灰名字;激活绿描边。
class _MoreSheetIconItem extends ConsumerWidget {
  const _MoreSheetIconItem({
    super.key,
    required this.tabId,
    required this.active,
    required this.onTap,
    required this.onLongPress,
  });

  final String tabId;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 固定项 icon/文案三分支:抽屉内恒用 outline 形态(与底栏 activeIcon 同源)。
    final (icon, label) = switch (tabId) {
      kNavTabMsg => (Icons.chat_bubble_outline, kNavTabMsgLabel),
      kNavTabWanling => (Icons.auto_awesome_outlined, kNavTabWanlingLabel),
      _ => (Icons.grid_view_outlined, kNavTabMiniProgramLabel),
    };
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: active
                  ? Border.all(color: AppColors.accentGreen, width: 1.5)
                  : null,
            ),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 32,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 抽屉网格项(agent):大圆角方形头像本体(在线绿点+未读角标)+灰名字;激活绿描边。
class _MoreSheetItem extends ConsumerWidget {
  const _MoreSheetItem({
    super.key,
    required this.agentId,
    required this.active,
    required this.onTap,
    required this.onLongPress,
  });

  final String agentId;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(agentByIdProvider(agentId));
    final unread = ref.watch(agentTabUnreadProvider(agentId));
    final name = agent?.name ?? agentId;
    final box = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              // 大圆角方形头像本体(无白底包裹);激活描边用 foregroundDecoration
              // 叠边框,不影响头像裁剪。
              Container(
                width: 64,
                height: 64,
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: active
                      ? Border.all(color: AppColors.accentGreen, width: 1.5)
                      : null,
                ),
                child: Avatar(name: name, url: agent?.avatarUrl, size: 64, radius: 16),
              ),
              if (unread > 0)
                Positioned(
                  top: -4,
                  right: -4,
                  child: UnreadBadge(count: unread),
                ),
              if (agent?.status == AgentStatus.online)
                Positioned(
                  right: 2,
                  bottom: 2,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: AppColors.accentGreen,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            name.characters.length > 6
                ? '${name.characters.take(6).join()}…'
                : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
    return box;
  }
}

/// 抽屉网格项(会话):大圆角方形头像(未读角标,无在线点)+灰名字;激活绿描边。
/// 点击由 HomePage onPickItem → _switchTab 路由跳聊天页。
class _MoreSheetConvItem extends ConsumerWidget {
  const _MoreSheetConvItem({
    super.key,
    required this.convId,
    required this.active,
    required this.onTap,
    required this.onLongPress,
  });

  final String convId;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 溢出项序列元素是 'conv:<convId>'，先去前缀再查会话(与底栏可见槽/编辑页同语义)。
    final cid = navConvIdOf(convId) ?? convId;
    final conv = ref.watch(convByIdProvider(cid));
    final name = conv?.displayName ?? cid;
    final unread = conv?.unreadCount ?? 0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 64,
                height: 64,
                foregroundDecoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: active
                      ? Border.all(color: AppColors.accentGreen, width: 1.5)
                      : null,
                ),
                child: Avatar(
                    name: name, url: conv?.displayAvatarUrl, size: 64, radius: 16),
              ),
              if (unread > 0)
                Positioned(
                  top: -4,
                  right: -4,
                  child: UnreadBadge(count: unread),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            name.characters.length > 6
                ? '${name.characters.take(6).join()}…'
                : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 抽屉网格项(小程序):大圆角方形 icon 头像+灰名字;激活绿描边。
/// 点击由 HomePage onPickItem → _switchTab push 容器页(与 conv 槽同构)。
class _MoreSheetMpItem extends ConsumerWidget {
  const _MoreSheetMpItem({
    super.key,
    required this.mpId,
    required this.active,
    required this.onTap,
    required this.onLongPress,
  });

  final String mpId;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 溢出项序列元素是 'mp:<appid>'，先去前缀再查小程序(与底栏可见槽同语义)。
    final appid = navMpAppidOf(mpId)!;
    final list = ref.watch(miniProgramsProvider).valueOrNull;
    MiniProgramInfo? mp;
    for (final m in list ?? const <MiniProgramInfo>[]) {
      if (m.appid == appid) {
        mp = m;
        break;
      }
    }
    final name = mp?.name ?? appid;
    final url = mp?.iconUrlFor(ref.watch(apiProvider).baseUrl);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 大圆角方形头像本体(无未读角标/在线点);激活描边用 foregroundDecoration
          // 叠边框,不影响头像裁剪(结构对齐 _MoreSheetConvItem)。
          Container(
            width: 64,
            height: 64,
            foregroundDecoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: active
                  ? Border.all(color: AppColors.accentGreen, width: 1.5)
                  : null,
            ),
            child: Avatar(
                name: name,
                url: (url == null || url.isEmpty) ? null : url,
                size: 64,
                radius: 16),
          ),
          const SizedBox(height: 6),
          Text(
            name.characters.length > 6
                ? '${name.characters.take(6).join()}…'
                : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 消息导航页:平铺后的独立 tab 页(原 A 组消息子页)。
///
/// 下拉入口:body 由 MiniProgramPullScope 承载——页头(appBar)移入页面卡片,
/// 下拉整页推下露出底层小程序面板;完成态经 panelOpenNotifier 通知 HomePage
/// 收缩底栏,页头贴底成为返回条。
class _MsgNavPage extends ConsumerWidget {
  const _MsgNavPage({
    required this.onOpenSidebar,
    required this.panelOpenNotifier,
  });

  final VoidCallback onOpenSidebar;
  final ValueNotifier<bool> panelOpenNotifier;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider).user;
    return Scaffold(
      // 白底:dpr 非整数倍时 AppBar 底缘半覆盖行会透出 Scaffold 底色,
      // 全局灰底(#EDEDED)在此显成一条淡灰缝线,页面本身是白底列表,底色改白让缝隐形
      backgroundColor: Colors.white,
      // appBar 交由 PullScope 页头承载(下拉入口),Scaffold 不再设 appBar
      body: MiniProgramPullScope(
        panelOpenNotifier: panelOpenNotifier,
        header: buildHomeAppBar(
          isWanling: false,
          user: user,
          onScan: () => context.push('/pair/scan'),
          onCreateAgent: () => showCreateAgentDialog(context, ref),
          onAvatarTap: onOpenSidebar,
        ),
        onRefresh: () => ref.read(conversationProvider.notifier).load(),
        onOpenApp: (appid) => openMiniProgramWith(
          ProviderScope.containerOf(context),
          appid,
        ),
        child: const Column(
          children: [
            ConnectionBanner(),
            LocalStoreBanner(),
            Expanded(child: MessagesPage()),
          ],
        ),
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
      backgroundColor: Colors.white,
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
          // 按钮未挂树(渲染对象尚未就位)时直接不弹:比兜底 Offset.zero
          // 把菜单弹到屏幕左上角诚实。
          if (box == null) return;
          // 锚点 = 按钮右下角:菜单右上角贴按钮右缘,顶部在按钮下方 8px
          final pos =
              box.localToGlobal(Offset(box.size.width, box.size.height));
          final selected = await showAppActionMenu(
            btnCtx,
            pos,
            align: AppMenuAlign.belowRight,
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
