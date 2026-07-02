import 'package:flutter/material.dart';
import 'package:nested_scroll_views/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../pages/agent_list_page.dart';
import '../pages/messages_page.dart';
import '../pages/profile_page.dart';
import '../providers/agent_provider.dart';
import '../providers/conversation_provider.dart' show totalUnreadProvider;
import '../widgets/connection_banner.dart';
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

    return Scaffold(
      body: Column(
        children: [
          const ConnectionBanner(),
          Expanded(
            child: NestedPageView(
              controller: _pageCtrl,
              onPageChanged: _onPageChanged,
              // 只有 2 页：A 组合页 + ProfilePage
              children: [
                _AGroupPage(
                  aIndex: _aIndex,
                  onAIndexChanged: (i) => setState(() => _aIndex = i),
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

  const _AGroupPage({
    required this.aIndex,
    required this.onAIndexChanged,
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

  /// 根据 aIndex 构建 AppBar 标题。
  /// - 消息（0）：标题「消息」，带「+」PopupMenu（加好友 / 发起群聊）
  ///   加好友路由 /friends/add 是 Task 4.2 范围,本期占位。
  /// - 万灵（1）：标题「万灵」，带「+」PopupMenuItem（扫一扫 / 创建 Agent）
  PreferredSizeWidget _buildAppBar() {
    if (widget.aIndex == 1) {
      return AppBar(
        title: const Text('万灵'),
        backgroundColor: const Color(0xFFF7F7F7),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.add, color: Color(0xFF07C160)),
            onSelected: (v) {
              if (v == 'scan') {
                context.push('/pair/scan');
              } else if (v == 'create') {
                _showCreateAgentDialog();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'scan', child: Text('扫一扫')),
              PopupMenuItem(value: 'create', child: Text('创建 Agent')),
            ],
          ),
        ],
      );
    }
    // 消息 tab:加好友(占位)+ 发起群聊。
    return AppBar(
      title: const Text('消息'),
      backgroundColor: const Color(0xFFF7F7F7),
      actions: [
        PopupMenuButton<String>(
          icon: const Icon(Icons.add, color: Color(0xFF07C160)),
          onSelected: (v) {
            if (v == 'add_friend') {
              context.push('/friends/add');
            } else if (v == 'create_group') {
              context.push('/conversations/new/group');
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'add_friend', child: Text('加好友')),
            PopupMenuItem(value: 'create_group', child: Text('发起群聊')),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      // 内部 PageView：消息↔万灵 横滑切换（AppBar 固定不动，仅内容跟手）。
      // 嵌套在外层 PageView（万灵↔我的）中：内层到边界后外层接管手势。
      // 用 AutomaticKeepAliveClientMixin（MessagesPage/AgentListPage 已加）保活两页 state。
      body: NestedPageView(
        controller: _innerCtrl,
        onPageChanged: widget.onAIndexChanged,
        children: const [
          MessagesPage(),
          AgentListPage(),
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
