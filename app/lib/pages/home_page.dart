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

/// 主容器：承载动态底部导航 + 多页 PageView。
///
/// 设计要点：
/// - 外层 NestedPageView 页 0 为 _AGroupPage（消息+万灵共享 AppBar），
///   页 1..N 为 pinned agent 的 sessions 页（AgentSessionsPage embedded 模式，
///   保活由其内部 AutomaticKeepAliveClientMixin 负责）
/// - 底部 NavTabBar：2 固定槽（消息/万灵）+ agent 头像槽 + 可选「更多」槽；
///   pinned 列表来自 effectiveNavOrderProvider 的 agent 子序列，槽位映射见 [_HomePageState._onNavTap]
/// - 「更多」槽激活时显示溢出 agent（_activeOverflowId），点按弹底部抽屉
///   （_showMoreSheet）点选切换
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

  /// A 组内部最后 tab(万灵)：跳去 agent 页前把 _aIndex 落在此，
  /// 从 A 组反滑回时内容已就位，无抖动（与原「我的」逻辑同口径）。
  static const int _aGroupLastIndex = 1;

  final PageController _pageCtrl = PageController(initialPage: 0);
  int _pageIndex = 0; // 0=A组(消息+万灵), i>=1 = pinned agent page i-1
  int _aIndex = 0; // A组内部:0=消息 1=万灵
  String? _activeOverflowId; // 「更多」槽激活的溢出 agent
  bool _sidebarOpen = false; // 左侧切换账号面板开关

  // build 时刷新,手势回调读取(避免回调里重复 watch)
  List<String> _pinnedAll = const [];
  bool _showMore = false;
  List<String> _visiblePinned = const [];
  List<String> _overflowPinned = const [];

  void _openSidebar() => setState(() => _sidebarOpen = true);
  void _closeSidebar() => setState(() => _sidebarOpen = false);

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  /// 底部导航点击：槽位编号 0=消息 1=万灵 2..=可见 agent，showMore 时 4=更多。
  void _onNavTap(int slot) {
    if (slot == 0 || slot == 1) {
      // 点消息/万灵：回 A 组页 + 切内部 index（沿用 addPostFrameCallback 防抖，
      // 与 _AGroupPage.didUpdateWidget 的像素守卫配合避免重复跳页）
      if (_pageIndex != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(0);
        });
      }
      setState(() => _aIndex = slot);
      return;
    }
    if (_showMore && slot == 4) {
      _showMoreSheet();
      return;
    }
    final agentIdx = slot - 2;
    if (agentIdx < 0 || agentIdx >= _visiblePinned.length) return;
    _jumpToAgentPage(_visiblePinned[agentIdx]);
  }

  /// 跳到指定 agent 的 sessions 页（page = 1 + pinned 下标）。
  /// 溢出 agent（下标 ≥ _kVisibleWhenOverflow）同时点亮「更多」槽。
  void _jumpToAgentPage(String agentId) {
    final page = 1 + _pinnedAll.indexOf(agentId);
    if (page < 1) return;
    setState(() {
      // 从 A 组反滑回时落在万灵,无抖动(与原「我的」逻辑同口径)
      _aIndex = _aGroupLastIndex;
      _activeOverflowId =
          (_showMore && _pinnedAll.indexOf(agentId) >= _kVisibleWhenOverflow)
              ? agentId
              : null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pageCtrl.hasClients && _pageCtrl.page?.round() != page) {
        _pageCtrl.jumpToPage(page);
      }
    });
  }

  /// PageView settle 后同步选中态(含滑入溢出 agent 页时点亮更多槽)。
  void _onPageChanged(int page) {
    setState(() {
      _pageIndex = page;
      if (page >= 1 && page - 1 < _pinnedAll.length) {
        final id = _pinnedAll[page - 1];
        _activeOverflowId =
            (_showMore && _pinnedAll.indexOf(id) >= _kVisibleWhenOverflow)
                ? id
                : null;
      } else {
        _activeOverflowId = null;
      }
    });
  }

  /// 底栏选中态:page 0 → _aIndex;agent 页 → 可见槽 2+i 或更多槽 4。
  int get _currentNavIndex {
    if (_pageIndex == 0) return _aIndex;
    final idx = _pageIndex - 1;
    if (!_showMore) return 2 + idx;
    return idx < _kVisibleWhenOverflow ? 2 + idx : 4;
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
                final active = id == _activeOverflowId;
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

  /// 全槽序列 → agent 子序列（Task 1 桥接:底栏/PageView 暂只消费 agent 槽,
  /// Task 3 slots 平铺后移除过滤）。
  static List<String> _agentsOf(List<String> order) =>
      [for (final id in order) if (!kNavFixedIds.contains(id)) id];

  @override
  Widget build(BuildContext context) {
    final totalUnread = ref.watch(totalUnreadProvider);
    _pinnedAll = _agentsOf(ref.watch(effectiveNavOrderProvider));
    _showMore = _pinnedAll.length >= _kOverflowThreshold;
    _visiblePinned = _showMore
        ? _pinnedAll.take(_kVisibleWhenOverflow).toList()
        : _pinnedAll;
    _overflowPinned =
        _showMore ? _pinnedAll.skip(_kVisibleWhenOverflow).toList() : [];

    // pin 列表收缩(取消固定/agent 删除/切账号)时按当前页 agent 身份判定落点:
    // 仍在列表(如前面的 agent 被移除,位置左移)→ 跳到收缩后的新位置,不回 A 组;
    // 已消失(unpin 当前页/agent 删除)→ 回 A 组页并按设计文档回落消息 tab。
    // 收缩通知同步于 rebuild 前,prev 即旧列表,据此取当前页 agent id。
    ref.listen(effectiveNavOrderProvider, (prev, next) {
      if (_pageIndex <= 0) return;
      final prevAgents = prev == null ? null : _agentsOf(prev);
      final nextAgents = _agentsOf(next);
      final oldIdx = _pageIndex - 1;
      final currentId = (prevAgents != null && oldIdx < prevAgents.length)
          ? prevAgents[oldIdx]
          : null;
      final newIdx = currentId == null ? -1 : nextAgents.indexOf(currentId);
      if (newIdx == oldIdx) return; // 身份与位置均未变(含内容相同的重复通知)
      if (newIdx >= 0) {
        _pageIndex = newIdx + 1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageCtrl.hasClients && _pageCtrl.page?.round() != newIdx + 1) {
            _pageCtrl.jumpToPage(newIdx + 1);
          }
        });
      } else {
        _activeOverflowId = null;
        _pageIndex = 0;
        _aIndex = 0; // 回退消息 tab(设计文档口径),随重建经 didUpdateWidget 驱动内层跳页
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(0);
        });
      }
    });

    final activeOverflow = _overflowPinned.contains(_activeOverflowId)
        ? _activeOverflowId
        : null;

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
                _AGroupPage(
                  aIndex: _aIndex,
                  onAIndexChanged: (i) => setState(() => _aIndex = i),
                  onOpenSidebar: _openSidebar,
                ),
                // pinned agent 页(保活由 AgentSessionsPage 内部 mixin 负责)
                for (final id in _pinnedAll)
                  KeyedSubtree(
                    key: ValueKey('nav-tab-$id'),
                    child: AgentSessionsPage(agentId: id, embedded: true),
                  ),
              ],
            ),
            bottomNavigationBar: NavTabBar(
              currentIndex: _currentNavIndex,
              totalUnread: totalUnread,
              agentTabs: [
                for (final id in _visiblePinned) _toNavAgentTab(id),
              ],
              showMore: _showMore,
              moreTab:
                  activeOverflow == null ? null : _toNavAgentTab(activeOverflow),
              onSlotTap: _onNavTap,
              onMoreTap: _showMoreSheet,
              onAgentReorder: (agentId, targetAgentIndex) =>
                  ref.read(navOrderProvider.notifier).reorder(
                        agentId,
                        // 新序列固定项前置 2 位,agent 子序列下标需偏移(临时桥接,Task 3 平铺后移除)
                        targetAgentIndex + 2,
                      ),
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

/// A 组合页：消息 + 万灵共享 1 个 AppBar，内部 IndexedStack 切换内容。
///
/// 作为 PageView 的 page 0（当前唯一页）。左右横滑仅用于 消息↔万灵 内层切换。
class _AGroupPage extends ConsumerStatefulWidget {
  final int aIndex; // 0=消息, 1=万灵
  final ValueChanged<int> onAIndexChanged;
  final VoidCallback onOpenSidebar;

  const _AGroupPage({
    required this.aIndex,
    required this.onAIndexChanged,
    required this.onOpenSidebar,
  });

  @override
  ConsumerState<_AGroupPage> createState() => _AGroupPageState();
}

class _AGroupPageState extends ConsumerState<_AGroupPage> {
  // 内部 PageView 的 controller：消息↔万灵 横滑切换。
  late final PageController _innerCtrl;

  @override
  void initState() {
    super.initState();
    _innerCtrl = PageController(initialPage: widget.aIndex);
  }

  @override
  void didUpdateWidget(covariant _AGroupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // HomePage 通过 aIndex prop 驱动内部跳转（点底部导航时）。
    // 跟手滑动时 onAIndexChanged 回调已更新 aIndex，这里跳转会重复 —— 用像素位置守卫。
    // 用 addPostFrameCallback 延后：didUpdateWidget 在 build 阶段，
    // 同步 jumpToPage 会触发内层 onPageChanged→外层 setState（"setState called during build"）。
    if (oldWidget.aIndex != widget.aIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_innerCtrl.hasClients &&
            _innerCtrl.page?.round() != widget.aIndex) {
          _innerCtrl.jumpToPage(widget.aIndex);
        }
      });
    }
  }

  @override
  void dispose() {
    _innerCtrl.dispose();
    super.dispose();
  }
  /// 万灵 tab 的「新建 Agent」弹窗。
  void _showCreateAgentDialog() {
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

  /// 根据 aIndex 构建 AppBar。
  /// - 消息 tab：靠左头像 + 用户名 + 简介（简介 >10 字截断加省略号）
  /// - 万灵 tab：头像在 leading + "万灵"标题靠左
  /// 两 tab 共用 + 号菜单（扫一扫 / 创建 Agent）使用 [buildHomeAppBar]。
  PreferredSizeWidget _buildAppBar() {
    final user = ref.watch(authProvider).user;
    return buildHomeAppBar(
      isWanling: widget.aIndex == 1,
      user: user,
      onScan: () => context.push('/pair/scan'),
      onCreateAgent: _showCreateAgentDialog,
      onAvatarTap: widget.onOpenSidebar,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      // 内部 PageView：消息↔万灵 横滑切换（AppBar 固定不动，仅内容跟手）。
      // 用 AutomaticKeepAliveClientMixin（MessagesPage/AgentListPage 已加）保活两页 state。
      // F5: banner 只在消息 tab 显示(用户主要场景),其他 tab 静默 fallback。
      body: NestedPageView(
        controller: _innerCtrl,
        onPageChanged: widget.onAIndexChanged,
        children: const [
          Column(
            children: [
              ConnectionBanner(),
              LocalStoreBanner(),
              Expanded(child: MessagesPage()),
            ],
          ),
          AgentListPage(),
        ],
      ),
    );
  }
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
