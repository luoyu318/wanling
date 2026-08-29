// 双层侧滑栏测试:左竖条(账号切换/长按编辑/添加) + 主面板(菜单/退出)。
// 原 AccountSidebar 单面板卡片测试随双层重构适配。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
// package_info_plus 未 re-export 其平台接口,这里直接引用该包的 transitive 依赖
// 以便在测试中把 Linux 实现(真实文件 IO,fake-async 下永不完成)换成可 mock 的通道实现。
// ignore: depend_on_referenced_packages
import 'package:package_info_plus_platform_interface/method_channel_package_info.dart';
// ignore: depend_on_referenced_packages
import 'package:package_info_plus_platform_interface/package_info_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/account_mark.dart';
import 'package:wanling_core/models/saved_login.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/theme/app_colors.dart';
import 'package:wanling_core/utils/secure_storage.dart';
import 'package:app/widgets/account_sidebar.dart';
import 'package:app/widgets/sidebar_profile_panel.dart';

/// package_info 通道名(package_info_plus 的 MethodChannelPackageInfo 所用)。
const _packageInfoChannel = MethodChannel('dev.fluttercommunity.plus/package_info');

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

    /// 当前项绿框高亮:竖条头像外层 Container 的 Border.all(accentGreen)。
    Finder currentHighlight() => find.byWidgetPredicate((w) {
          if (w is! Container) return false;
          final deco = w.decoration;
          return deco is BoxDecoration &&
              deco.border is Border &&
              (deco.border as Border).top.color == AppColors.accentGreen;
        });

    testWidgets('竖条渲染账号名 + 当前项绿框高亮 + 主面板显示用户名', (tester) async {
      await pumpSidebar(tester);
      // 竖条账号名(备注 > 昵称 > 账号名)
      expect(find.text('正式服'), findsOneWidget);
      expect(find.text('测试服'), findsOneWidget);
      // 当前项(index 0)绿框
      expect(currentHighlight(), findsOneWidget);
      // 主面板用户头部:名字 + 简介
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('点非当前头像触发 switchTo 并回调 onClose', (tester) async {
      await pumpSidebar(tester);
      await tester.tap(find.text('测试服'));
      await tester.pumpAndSettle();
      expect(logoutCalls, 1);
      expect(loginCalls, ['uB:pB']);
      expect(closeCalls, 1);
    });

    testWidgets('点当前头像不触发切换', (tester) async {
      await pumpSidebar(tester);
      await tester.tap(find.text('正式服'));
      await tester.pumpAndSettle();
      expect(logoutCalls, 0);
      expect(loginCalls, isEmpty);
      expect(closeCalls, 0);
    });

    testWidgets('空列表:竖条只有添加按钮 + 主面板菜单仍在', (tester) async {
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
      // 旧「暂无记录」空态已随账号卡片一并移除
      expect(find.text('暂无记录'), findsNothing);
      expect(find.text('添加'), findsOneWidget);
      expect(find.byType(SidebarProfilePanel), findsOneWidget);
      expect(find.text('编辑资料'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
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

    testWidgets('长按头像弹菜单:编辑 dialog 并保存', (tester) async {
      await pumpSidebar(tester);
      // 长按第二个账号头像(测试服,非当前)弹出动作菜单
      await tester.longPress(find.text('测试服'));
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

    testWidgets('长按头像弹菜单:复制生成完整副本', (tester) async {
      await pumpSidebar(tester);
      final before = notifier.state.logins.length;
      await tester.longPress(find.text('测试服'));
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

    testWidgets('长按头像弹菜单:删除弹确认并删除', (tester) async {
      await pumpSidebar(tester);
      await tester.longPress(find.text('测试服'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('确认删除'), findsOneWidget);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(notifier.state.logins.length, 1);
    });

    testWidgets('点添加弹 dialog', (tester) async {
      await pumpSidebar(tester);
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(find.text('添加账号'), findsOneWidget);
    });

    testWidgets('主面板退出登录二次确认弹窗', (tester) async {
      await pumpSidebar(tester);
      await tester.tap(find.text('退出登录'));
      await tester.pumpAndSettle();
      expect(find.text('确定要退出吗？'), findsOneWidget);
    });

    testWidgets('关于菜单显示版本号', (tester) async {
      // PackageInfo.fromPlatform 默认走 Linux 平台实现(真实文件 IO),
      // 在 fake-async 测试环境永不完成;改用 MethodChannel 实现 + mock 通道。
      final defaultInstance = PackageInfoPlatform.instance;
      PackageInfoPlatform.instance = MethodChannelPackageInfo();
      addTearDown(() => PackageInfoPlatform.instance = defaultInstance);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _packageInfoChannel,
        (call) async => {
          'appName': 'wanling',
          'packageName': 'com.wanling.app',
          'version': '1.2.3',
          'buildNumber': '45',
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(_packageInfoChannel, null);
      });
      await pumpSidebar(tester);
      // 版本号显示在关于行 trailing
      expect(find.text('v1.2.3+45'), findsOneWidget);
    });
  });
}
