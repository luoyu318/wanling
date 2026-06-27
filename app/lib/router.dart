import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'pages/about_page.dart';
import 'pages/agent_detail_page.dart';
import 'pages/change_password_page.dart';
import 'pages/chat_page.dart';
import 'pages/edit_profile_page.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'pages/pair_select_agent_page.dart';
import 'pages/scan_pair_page.dart';
import 'pages/select_account_page.dart';
import 'pages/splash_page.dart';
import 'providers/auth_provider.dart';
import 'services/notification_service.dart';

/// 全局 navigator key：通知点击回调需要拿到 navigator 做 push（无 BuildContext）。
final navigatorKey = GlobalKey<NavigatorState>();

/// 页面进入/返回的横向平移偏移量。
///
/// 进入时：新页面从右侧 1.0 倍宽度处推入（Offset 是相对于自身的比例，
/// dx=1.0 表示右移一个自身宽度，即从屏幕右侧外滑入）。
/// 返回时：reverse 动画自动把它推回右侧。
const _kEnterOffset = Offset(1.0, 0.0);

/// 自定义横向平移转场：IM 风格的「右侧推入/推出」。
///
/// 设计决策：
/// - 不用 CupertinoPageTransitionsBuilder：它时长固定 500ms 且无法配置，
///   这里要 200ms 的利落感。
/// - 不用 pageTransitionsTheme + MaterialPageRoute：那条路径时长由 builder 决定
///   （Cupertino=500ms），改不了 300ms 以下。
/// - 用 CustomTransitionPage + 手写 SlideTransition：
///   ① 时长完全自控（200ms）；
///   ② 样式为纯横向平移，对齐主流 IM；
///   ③ 代价：失去 iOS 边缘左滑跟手返回（TransitionsBuilder 签名无 route 参数，
///      无法挂 Cupertino 的手势检测器）——可接受，返回按钮/系统返回键动画正常。
Widget _slideTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  // easeOut：进入时快速启动后平滑减速，符合自然物理感，避免线性生硬。
  final curve = CurvedAnimation(parent: animation, curve: Curves.easeOut);
  return SlideTransition(
    position: Tween<Offset>(
      begin: _kEnterOffset,
      end: Offset.zero,
    ).animate(curve),
    child: child,
  );
}

/// 构建统一的页面转场 Page。
///
/// 必须传入 key（GoRouterState.pageKey）：pushReplacement 时，新旧 page 的 key
/// 不同，Flutter 才会销毁旧 page 的 State 并重建新 page（触发 initState）。
/// 缺 key 时 Flutter 会复用旧 State，导致 initState 不重跑——表现为 ChatPage
/// 切换会话时 markRead / setActiveConv 等初始化逻辑失效（未读不清等 bug）。
CustomTransitionPage<void> _cupertinoPage({
  required Widget child,
  required ValueKey<String> key,
}) {
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 200),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: _slideTransition,
  );
}

/// 全局 GoRouter 配置。
///
/// 设计决策：routerProvider 内部 ref.watch(authProvider)，auth 状态变化时
/// GoRouter 会被重建并触发 redirect。auth 变化频率极低（登录/登出/401/restore 完成），
/// 重建成本可忽略，换来代码简洁——无需手动管理 refreshListenable。
/// 替代方案（ref.read + refreshListenable）更复杂且收益小，故不采用。
final routerProvider = Provider<GoRouter>((ref) {
  // watch 而非 read：auth 变化时 router 重建，redirect 重新判断登录态路由
  final auth = ref.watch(authProvider);
  return GoRouter(
    navigatorKey: navigatorKey,
    initialLocation: '/',
    redirect: (ctx, state) {
      // 切换账号(isSwitching)期间视同已登录:logout→login 中间态不让 router 误跳 /login。
      final loggedIn = auth.isAuthenticated || auth.isSwitching;
      // 未登录白名单：登录页 + 账号选择页（后者从登录页 push 进入，必须放行，
      // 否则会被踢回 /login 导致 SelectAccountPage 进不去）。
      final authFlowPaths = const {'/login', '/select-account'};
      final isAuthFlow = authFlowPaths.contains(state.matchedLocation);

      // 冷启动从通知拉起：如果未消费的 launchPayload 存在 + 已登录，
      // 优先跳到对应 ChatPage（仅当当前位置还是 / 初始位置才跳，避免覆盖用户手动跳转）
      final launchPayload = NotificationService.instance.consumeLaunchPayload();
      if (launchPayload != null && loggedIn &&
          state.matchedLocation == '/') {
        return '/chat/${launchPayload.convId}?agentId=${launchPayload.agentId}';
      }

      if (!loggedIn && !isAuthFlow) return '/login';
      if (loggedIn && isAuthFlow) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        pageBuilder: (context, state) => _cupertinoPage(
          child: const SplashPage(),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) => _cupertinoPage(
          child: const LoginPage(),
          key: state.pageKey,
        ),
      ),
      // 账号选择页：从 LoginPage「切换服务器/账号」入口进入。
      // 注册到 router 而非 Navigator.push(MaterialPageRoute)，让转场跟全局
      // 200ms 横向平移一致。
      GoRoute(
        path: '/select-account',
        pageBuilder: (context, state) => _cupertinoPage(
          child: const SelectAccountPage(),
          key: state.pageKey,
        ),
      ),
      // 底部导航容器：HomePage 内部用 PageView 实现 tab 切换（支持左右跟手滑动）
      GoRoute(
        path: '/',
        pageBuilder: (context, state) => _cupertinoPage(
          child: const HomePage(),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: '/agent/:id',
        pageBuilder: (context, state) => _cupertinoPage(
          child: AgentDetailPage(agentId: state.pathParameters['id']!),
          key: state.pageKey,
        ),
      ),
      // Chat 路由：convId 走 path 参数，agentId 走 query。
      // 调用方在 push 前必须已 findOrCreateConversation 拿到 convId。
      GoRoute(
        path: '/chat/:convId',
        pageBuilder: (context, state) {
          final convId = state.pathParameters['convId']!;
          final agentId = state.uri.queryParameters['agentId']!;
          return _cupertinoPage(
            child: ChatPage(convId: convId, agentId: agentId),
            key: state.pageKey,
          );
        },
      ),
      GoRoute(
        path: '/change-password',
        pageBuilder: (context, state) => _cupertinoPage(
          child: const ChangePasswordPage(),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: '/profile/edit',
        pageBuilder: (context, state) => _cupertinoPage(
          child: const EditProfilePage(),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: '/about',
        pageBuilder: (context, state) => _cupertinoPage(
          child: const AboutPage(),
          key: state.pageKey,
        ),
      ),
      // 扫码配对：hermes 终端扫码授权连接 Agent。
      GoRoute(
        path: '/pair/scan',
        pageBuilder: (context, state) => _cupertinoPage(
          child: const ScanPairPage(),
          key: state.pageKey,
        ),
      ),
      GoRoute(
        path: '/pair/select-agent',
        pageBuilder: (context, state) {
          final ticket = state.uri.queryParameters['ticket'] ?? '';
          return _cupertinoPage(
            child: PairSelectAgentPage(ticketId: ticket),
            key: state.pageKey,
          );
        },
      ),
    ],
  );
});
