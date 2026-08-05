import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/models/account_mark.dart';
import 'package:app/models/saved_login.dart';
import 'package:app/models/user.dart';
import 'package:app/providers/auth_provider.dart';
import 'package:app/providers/saved_logins_provider.dart';
import 'package:app/services/api_service.dart';
import 'package:app/utils/secure_storage.dart';
import 'package:app/widgets/account_sidebar.dart';

void main() {
  group('accountCardTitle', () {
    test('label 优先', () {
      const l = SavedLogin(
        server: 'http://a',
        username: 'u',
        password: 'p',
        label: '备注',
      );
      expect(accountCardTitle(l), '备注');
    });

    test('无 label 用 username', () {
      const l = SavedLogin(server: 'http://a', username: 'u', password: 'p');
      expect(accountCardTitle(l), 'u');
    });

    test('username 空回退 server', () {
      const l = SavedLogin(server: 'http://a', username: '', password: 'p');
      expect(accountCardTitle(l), 'http://a');
    });
  });

  group('AccountSidebar', () {
    late ProviderContainer container;
    late SavedLoginsNotifier notifier;
    int logoutCalls = 0;
    List<String> loginCalls = [];
    int closeCalls = 0;

    Future<void> pumpSidebar(WidgetTester tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(body: AccountSidebar(onClose: () => closeCalls++)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final storage = SecureStorage(deviceId: 'test-device');
      logoutCalls = 0;
      loginCalls = [];
      closeCalls = 0;
      notifier = SavedLoginsNotifier(
        prefs: prefs,
        storage: storage,
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async => logoutCalls++,
        onLogin: (u, p) async => loginCalls.add('$u:$p'),
        onSwitchingChange: (_) {},
      );
      await notifier.add(
        'http://prod',
        'uA',
        'pA',
        label: '正式服',
        mark: const AccountMark(colorIndex: 3),
      );
      await notifier.add('http://test', 'uB', 'pB', label: '测试服');
      notifier.select(0);
      final authNotifier = AuthNotifier(
        ApiService(baseUrl: 'http://test.local'),
      );
      authNotifier.state = AuthState(
        user: User(
          id: 'u1',
          username: 'alice',
          nickname: 'Alice',
          bio: 'Hello',
          createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
        ),
        token: 't',
        isRestoring: false,
      );
      container = ProviderContainer(
        overrides: [
          savedLoginsProvider.overrideWith((ref) => notifier),
          authProvider.overrideWith((ref) => authNotifier),
        ],
      );
    });

    testWidgets('渲染账号卡片与当前标记 + 用户头部', (tester) async {
      await pumpSidebar(tester);
      expect(find.text('Alice'), findsWidgets);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('正式服'), findsOneWidget);
      expect(find.text('测试服'), findsOneWidget);
      expect(find.text('uA @ http://prod'), findsOneWidget);
      expect(find.text('当前'), findsOneWidget);
    });

    testWidgets('点非当前卡片触发 switchTo 并回调 onClose', (tester) async {
      await pumpSidebar(tester);
      await tester.tap(find.text('测试服'));
      await tester.pumpAndSettle();
      expect(logoutCalls, 1);
      expect(loginCalls, ['uB:pB']);
      expect(closeCalls, 1);
    });

    testWidgets('点当前卡片不触发切换', (tester) async {
      await pumpSidebar(tester);
      await tester.tap(find.text('正式服'));
      await tester.pumpAndSettle();
      expect(logoutCalls, 0);
      expect(loginCalls, isEmpty);
      expect(closeCalls, 0);
    });

    testWidgets('空列表显示暂无记录 + 添加按钮可用', (tester) async {
      final emptyNotifier = SavedLoginsNotifier(
        prefs: await SharedPreferences.getInstance(),
        storage: SecureStorage(deviceId: 'test-device'),
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async {},
        onSwitchingChange: (_) {},
      );
      final c = ProviderContainer(
        overrides: [savedLoginsProvider.overrideWith((ref) => emptyNotifier)],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(body: AccountSidebar(onClose: () {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂无记录'), findsOneWidget);
      expect(find.text('添加服务器'), findsOneWidget);
    });

    testWidgets('切换失败显示错误提示且不关闭面板', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final failNotifier = SavedLoginsNotifier(
        prefs: prefs,
        storage: SecureStorage(deviceId: 'test-device'),
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async => throw Exception('密码错误'),
        onSwitchingChange: (_) {},
      );
      await failNotifier.add('http://a', 'u1', 'p1', label: '账号A');
      await failNotifier.add('http://b', 'u2', 'p2', label: '账号B');
      failNotifier.select(0);
      final c = ProviderContainer(
        overrides: [savedLoginsProvider.overrideWith((ref) => failNotifier)],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(body: AccountSidebar(onClose: () {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('账号B'));
      await tester.pumpAndSettle();
      expect(find.textContaining('密码错误'), findsOneWidget);
    });

    testWidgets('切换中显示 loading 遮罩', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final slowNotifier = SavedLoginsNotifier(
        prefs: prefs,
        storage: SecureStorage(deviceId: 'test-device'),
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        },
        onSwitchingChange: (_) {},
      );
      await slowNotifier.add('http://a', 'u1', 'p1', label: '账号A');
      await slowNotifier.add('http://b', 'u2', 'p2', label: '账号B');
      slowNotifier.select(0);
      final c = ProviderContainer(
        overrides: [savedLoginsProvider.overrideWith((ref) => slowNotifier)],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            home: Scaffold(body: AccountSidebar(onClose: () {})),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('账号B'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('切换中…'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('切换中…'), findsNothing);
    });

    testWidgets('点 ⋯ 弹编辑 dialog 并保存', (tester) async {
      await pumpSidebar(tester);
      // 第二张卡(测试服,非当前)的 ⋯ 菜单
      await tester.tap(find.byIcon(Icons.more_horiz).at(1));
      await tester.pumpAndSettle();
      expect(find.text('编辑'), findsOneWidget);
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      expect(find.text('编辑账号'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('sidebar_label_field')),
        '改备注',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(notifier.state.logins[1].label, '改备注');
    });

    testWidgets('点 ⋯ 复制生成完整副本', (tester) async {
      await pumpSidebar(tester);
      final before = notifier.state.logins.length;
      await tester.tap(find.byIcon(Icons.more_horiz).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制'));
      await tester.pumpAndSettle();
      expect(notifier.state.logins.length, before + 1);
      final clone = notifier.state.logins.last;
      expect(clone.server, 'http://test');
      expect(clone.username, 'uB_copy');
      expect(clone.label, '测试服');
      // 不改变当前选中
      expect(notifier.state.selectedIndex, 0);
    });

    testWidgets('点 ⋯ 删除弹确认并删除', (tester) async {
      await pumpSidebar(tester);
      await tester.tap(find.byIcon(Icons.more_horiz).at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('确认删除'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(notifier.state.logins.length, 1);
    });

    testWidgets('点添加服务器弹 dialog', (tester) async {
      await pumpSidebar(tester);
      await tester.tap(find.text('添加服务器'));
      await tester.pumpAndSettle();
      expect(find.text('添加账号'), findsOneWidget);
    });
  });
}
