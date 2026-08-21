// desktop/test/app_canvas_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/utils/secure_storage.dart';
import 'package:wanling_desktop/providers/conv_list_width_provider.dart';
import 'package:wanling_desktop/shell/app_canvas.dart';
import 'package:wanling_desktop/shell/nav_rail.dart';
import 'package:wanling_desktop/shell/resize_handle.dart';
import 'package:wanling_desktop/shell/title_bar.dart';
import 'package:wanling_desktop/theme/desktop_theme.dart';

/// 空 savedLogins 种子(镜像 nav_rail_test,AccountSwitcher 不拉存储链)。
class _EmptySavedLogins extends SavedLoginsNotifier {
  _EmptySavedLogins(SharedPreferences prefs)
    : super(
        prefs: prefs,
        storage: SecureStorage(deviceId: 'test'),
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async {},
        onSwitchingChange: (s) {},
      );
}

void main() {
  testWidgets('画布渲染 TitleBar/工具条/双卡片与右底 8px 边距,宽度随 provider', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          (ref) => AuthNotifier(ApiService(baseUrl: '')),
        ),
        savedLoginsProvider.overrideWith((ref) => _EmptySavedLogins(prefs)),
      ],
    );
    addTearDown(container.dispose);

    // NavRail 依赖 GoRouter 路由上下文,经单路由承载画布
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: '/messages',
            routes: [
              GoRoute(
                path: '/messages',
                builder: (c, s) => AppCanvas(
                  conversationCard: const Text('conv'),
                  chatCard: const Text('chat'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 结构:标题栏/透明工具条/分割线/双卡片 Slot 内容
    expect(find.byType(AppCanvas), findsOneWidget);
    expect(find.byType(TitleBar), findsOneWidget);
    expect(find.byType(NavRail), findsOneWidget);
    expect(find.byType(ResizeHandle), findsOneWidget);
    expect(find.text('conv'), findsOneWidget);
    expect(find.text('chat'), findsOneWidget);

    // 画布底色 = canvasColor(测试默认 light)
    final scaffold = tester.widget<Scaffold>(
      find
          .descendant(of: find.byType(AppCanvas), matching: find.byType(Scaffold))
          .first,
    );
    expect(scaffold.backgroundColor, DesktopTheme.canvasColor(Brightness.light));

    // 窗口右/底 8px:唯一 EdgeInsets.only(right: 8, bottom: 8),提到最外层
    expect(
      find.byWidgetPredicate(
        (w) => w is Padding && w.padding == const EdgeInsets.only(right: 8, bottom: 8),
      ),
      findsOneWidget,
    );

    // 外层 Row 结构:NavRail 通顶(顶边贴画布 0 且贯穿到 底边距),
    // TitleBar 收窄主体区(顶边贴 0,左边缘在 NavRail 右侧)
    expect(tester.getTopLeft(find.byType(NavRail)).dy, 0);
    expect(
      tester.getBottomRight(find.byType(NavRail)).dy,
      moreOrLessEquals(600 - 8),
    );
    expect(tester.getTopLeft(find.byType(TitleBar)).dy, 0);
    expect(
      tester.getTopLeft(find.byType(TitleBar)).dx,
      tester.getTopRight(find.byType(NavRail)).dx,
    );

    // 会话卡片槽默认宽 280(convListWidthProvider 默认值)
    expect(
      find.byWidgetPredicate((w) => w is SizedBox && w.width == 280),
      findsOneWidget,
    );

    // actions 缺省走 windowActionsProvider(默认 null) → 标题栏系统按钮隐藏
    expect(find.byKey(const ValueKey('titlebar_minimize')), findsNothing);

    // provider 驱动宽度:调宽后卡片槽变 320
    container.read(convListWidthProvider.notifier).setWidth(320);
    await tester.pump();
    expect(
      find.byWidgetPredicate((w) => w is SizedBox && w.width == 320),
      findsOneWidget,
    );
  });
}
