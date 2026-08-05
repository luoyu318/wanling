import 'package:flutter/material.dart';
import 'package:nested_scroll_views/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/user.dart';
import '../pages/agent_list_page.dart';
import '../pages/messages_page.dart';
import '../pages/profile_page.dart';
import '../providers/agent_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/conversation_provider.dart' show totalUnreadProvider;
import '../theme/app_colors.dart';
import '../widgets/account_sidebar.dart';
import '../widgets/app_action_menu.dart';
import '../widgets/avatar.dart';
import '../widgets/connection_banner.dart';
import '../widgets/local_store_banner.dart';
import '../widgets/feedback/app_dialog.dart';
import '../widgets/unread_badge.dart';

/// 主容器：承载底部导航 + PageView 的 2 个 page。
///
/// 设计要点：
/// - PageView 只有 2 页：page 0 = _AGroupPage（消息+万灵共享 AppBar），
///   page 1 = ProfilePage（独立 SliverAppBar，跟手进出）
/// - _pageIndex 跟踪 PageView 当前页，_aIndex 跟踪 A 组内部 index
/// - 底部 BottomNavigationBar 全局共享，3 item 固定不动
/// - 万灵↔我的 滑动时整页（含 AppBar/资料卡）跟手移动
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final PageController _pageCtrl = PageController(initialPage: 0);
  int _pageIndex = 0; // PageView 当前页：0=A 组, 1=我的
  int _aIndex = 0; // A 组内部 index：0=消息, 1=万灵
  bool _sidebarOpen = false; // 左侧切换账号面板开关

  void _openSidebar() => setState(() => _sidebarOpen = true);
  void _closeSidebar() => setState(() => _sidebarOpen = false);

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  /// 底部导航点击：3 item → 2 page + A 组内部 index。
  /// - 点消息/万灵：跳 page 0 + 切 _aIndex
  /// - 点我的：跳 page 1
  /// A 组最后一个子页面的 index（紧邻"我的"，当前是万灵）。
  /// 未来 A 组扩展子页时，这里自动取最后一个。
  static const int _aGroupLastIndex = 1;

  void _onNavTap(int navIndex) {
    if (navIndex == 0 || navIndex == 1) {
      // 点消息/万灵：先确保在 A 组页（瞬切无动画），再切内部 index。
      // 用 addPostFrameCallback 延后 jumpToPage：避免在 build 阶段同步触发
      // onPageChanged→setState（"setState called during build"）。
      if (_pageIndex != 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(0);
        });
      }
      setState(() => _aIndex = navIndex);
    } else {
      // 点我的：瞬切到 page 1（无左滑动画）。
      // 提前把 _aIndex 设为 A 组最后一个子页面（万灵），
      // 让 _AGroupPage 的内层 controller 提前跳到万灵 ——
      // 这样反滑回 A 组时内层已经在万灵，无抖动（避免滑动时才 jumpToPage）。
      setState(() => _aIndex = _aGroupLastIndex);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(1);
      });
    }
  }

  /// PageView 页面变化（跟手滑动 settle 后触发）。
  void _onPageChanged(int pageIndex) {
    setState(() {
      _pageIndex = pageIndex;
      // 跟手从我的(page 1)反滑回 A 组(page 0)时，
      // _aIndex 已经在 _onNavTap 提前设为万灵（_aGroupLastIndex），
      // 这里不需要再改 _aIndex。
    });
  }

  /// 底部导航选中态：page 1 → 2（我的）；page 0 → _aIndex（消息/万灵）。
  int get _currentNavIndex =>
      _pageIndex == 1 ? 2 : _aIndex;

  @override
  Widget build(BuildContext context) {
    final totalUnread = ref.watch(totalUnreadProvider);

    return PopScope(
      canPop: !_sidebarOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sidebarOpen) _closeSidebar();
      },
      // Stack 在 Scaffold 外层：遮罩 + 侧滑面板覆盖整个 Scaffold(含底部 tab 栏)
      child: Stack(
        children: [
          Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: NestedPageView(
                    controller: _pageCtrl,
                    onPageChanged: _onPageChanged,
                    children: [
                      _AGroupPage(
                        aIndex: _aIndex,
                        onAIndexChanged: (i) => setState(() => _aIndex = i),
                        onOpenSidebar: _openSidebar,
                      ),
                      const ProfilePage(),
                    ],
                  ),
                ),
              ],
            ),
            bottomNavigationBar: BottomNavigationBar(
              currentIndex: _currentNavIndex,
              backgroundColor: const Color(0xFFF7F7F7),
              onTap: _onNavTap,
              items: [
                BottomNavigationBarItem(
                  icon: _TabIcon(
                    icon: Icons.chat_bubble_outline,
                    badge: totalUnread,
                  ),
                  activeIcon: _TabIcon(
                    icon: Icons.chat_bubble,
                    badge: totalUnread,
                  ),
                  label: '消息',
                ),
                const BottomNavigationBarItem(
                  icon: Icon(Icons.auto_awesome_outlined),
                  activeIcon: Icon(Icons.auto_awesome),
                  label: '万灵',
                ),
                const BottomNavigationBarItem(
                  icon: Icon(Icons.person_outline),
                  activeIcon: Icon(Icons.person),
                  label: '我的',
                ),
              ],
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
                child: Material(
                  type: MaterialType.transparency,
                  child: AccountSidebar(onClose: _closeSidebar),
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
/// 作为 PageView 的 page 0。万灵↔我的 滑动时，这个 page（含 AppBar）
/// 整体跟手左移，AppBar 不卡在 HomePage 原地。
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
  // 嵌套 PageView 默认手势行为：内层先消费横滑，内层到边界后外层（万灵↔我的）接管。
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
      // 嵌套在外层 PageView（万灵↔我的）中：内层到边界后外层接管手势。
      // 用 AutomaticKeepAliveClientMixin（MessagesPage/AgentListPage 已加）保活两页 state。
      // F5: banner 只在消息 tab 显示(用户主要场景),其他 tab 静默 fallback。
      body: NestedPageView(
        controller: _innerCtrl,
        onPageChanged: widget.onAIndexChanged,
        children: [
          Column(
            children: const [
              ConnectionBanner(),
              LocalStoreBanner(),
              Expanded(child: MessagesPage()),
            ],
          ),
          const AgentListPage(),
        ],
      ),
    );
  }
}

/// tab icon + badge 包装。badge > 0 时右上角小红圆。
class _TabIcon extends StatelessWidget {
  final IconData icon;
  final int badge;
  const _TabIcon({required this.icon, required this.badge});

  @override
  Widget build(BuildContext context) {
    if (badge <= 0) return Icon(icon);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(icon),
        Positioned(
          top: -6,
          right: -10,
          child: UnreadBadge(count: badge, radius: 8),
        ),
      ],
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
