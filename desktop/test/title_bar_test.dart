// desktop/test/title_bar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_desktop/shell/title_bar.dart';

/// 记录调用的 fake WindowActions。
class _FakeActions implements WindowActions {
  int minimizeCalls = 0;
  int maximizeCalls = 0;
  int closeCalls = 0;
  @override
  Future<void> minimize() async => minimizeCalls++;
  @override
  Future<void> toggleMaximize() async => maximizeCalls++;
  @override
  Future<void> close() async => closeCalls++;
  // 抽象含 dragWindow,补 no-op 以满足 implements(测试不断言拖拽)。
  @override
  Future<void> dragWindow() async {}
  @override
  Future<bool> get isMaximized async => false;
  @override
  Stream<void> get onStateChanged => const Stream.empty();
}

/// 已登录 auth 种子(镜像 wanling_page_test 模式):头像数据源。
class _LoggedInAuth extends AuthNotifier {
  _LoggedInAuth() : super(ApiService(baseUrl: '')) {
    state = AuthState(
      token: 'test-token',
      user: User(
        id: 'u1',
        username: 'wan',
        nickname: '测试用户',
        createdAt: DateTime(2026, 1, 1),
      ),
    );
  }
}

void main() {
  // Avatar 经 settingsProvider 读 SharedPreferences(baseUrl 拼接),需 mock。
  Future<void> pump(WidgetTester tester, WindowActions actions) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [authProvider.overrideWith((ref) => _LoggedInAuth())],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: TitleBar(actions: actions),
          ),
        ),
      ),
    );
  }

  testWidgets('三个系统按钮分别触发对应动作', (tester) async {
    final actions = _FakeActions();
    await pump(tester, actions);
    await tester.tap(find.byKey(const ValueKey('titlebar_minimize')));
    await tester.tap(find.byKey(const ValueKey('titlebar_maximize')));
    await tester.tap(find.byKey(const ValueKey('titlebar_close')));
    await tester.pump();
    expect(actions.minimizeCalls, 1);
    expect(actions.maximizeCalls, 1);
    expect(actions.closeCalls, 1);
  });

  testWidgets('标题栏渲染用户头像且无「万灵」文案', (tester) async {
    await pump(tester, _FakeActions());
    expect(find.byKey(const ValueKey('titlebar_logo')), findsOneWidget);
    // logo 位换成头像后不再渲染产品名文案。
    expect(find.text('万灵'), findsNothing);
    // 头像 fallback 字母瓦片取 displayName 首字。
    expect(find.text('测'), findsOneWidget);
  });
}
