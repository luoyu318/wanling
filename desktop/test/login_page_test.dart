// desktop/test/login_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/saved_login.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/services/api_response.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/utils/secure_storage.dart';
import 'package:wanling_desktop/pages/login_page.dart';
import 'package:wanling_desktop/widgets/account_switcher.dart';

/// 种子 savedLogins:notifier 编排逻辑是真的(switchTo 照跑),
/// 仅 state 预灌 + 回调记录,零存储/网络副作用(与 Task 3 种子模式同族)。
class _SeededSavedLogins extends SavedLoginsNotifier {
  final List<String> calls;
  _SeededSavedLogins(SharedPreferences prefs, List<SavedLogin> seed, this.calls)
    : super(
        prefs: prefs,
        storage: SecureStorage(deviceId: 'test'),
        onLogout: ({bool silent = false}) async => calls.add('logout:$silent'),
        onLogin: (u, p) async => calls.add('login:$u/$p'),
        onSwitchingChange: (s) {},
      ) {
    state = SavedLoginsState(
      logins: seed,
      selectedIndex: seed.isEmpty ? -1 : 0,
    );
  }
}

/// 登录必失败的 auth:notifier 真体,仅 login 抛 ApiException。
class _FailingAuth extends AuthNotifier {
  _FailingAuth() : super(ApiService(baseUrl: ''));
  @override
  Future<void> login(String username, String password) async {
    state = state.copyWith(isLoading: true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    state = state.copyWith(isLoading: false);
    throw ApiException('unauthorized', '用户名或密码错误');
  }
}

const _server = 'http://10.10.11.198:18008';

SavedLogin _account(String username, {String password = 'pw'}) =>
    SavedLogin(server: _server, username: username, password: password);

Future<SharedPreferences> _mockPrefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

void main() {
  testWidgets('登录表单渲染:地址/用户名/密码/记住账号/登录按钮,无已存账号时无切换器', (tester) async {
    final prefs = await _mockPrefs();
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          (ref) => AuthNotifier(ApiService(baseUrl: '')),
        ),
        savedLoginsProvider.overrideWith(
          (ref) => _SeededSavedLogins(prefs, [], []),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DesktopLoginPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('记住账号'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.byType(AccountSwitcher), findsNothing);
    expect(find.text('配对码绑定'), findsOneWidget);
  });

  testWidgets('已存账号切换:2 账号下拉项可见,登出态选择走 loginWith(无多余 logout)', (tester) async {
    final prefs = await _mockPrefs();
    final calls = <String>[];
    final accounts = [_account('kuro'), _account('shiro', password: 'pw2')];
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          (ref) => AuthNotifier(ApiService(baseUrl: '')),
        ),
        savedLoginsProvider.overrideWith(
          (ref) => _SeededSavedLogins(prefs, accounts, calls),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DesktopLoginPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 切换器显示当前账号,下拉含两条账号项
    expect(find.byType(AccountSwitcher), findsOneWidget);
    expect(find.text('kuro@$_server'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('account_switcher_button')));
    await tester.pumpAndSettle();
    // kuro@ 出现两处:切换器当前标签 + 下拉项;shiro@ 仅下拉项
    expect(find.text('kuro@$_server'), findsNWidgets(2));
    expect(find.text('shiro@$_server'), findsOneWidget);

    await tester.tap(find.text('shiro@$_server'));
    await tester.pumpAndSettle();

    // 登出态用 loginWith:select(1) + 凭据登录,不调 logout(未登录时多余且
    // 会触发 server 黑名单请求;switchTo 对 i==selectedIndex 还是 no-op)
    expect(calls, ['login:shiro/pw2']);
    expect(container.read(savedLoginsProvider).selectedIndex, 1);
  });

  testWidgets('登出态点当前选中账号也触发登录(loginWith 无 no-op 短路)', (tester) async {
    final prefs = await _mockPrefs();
    final calls = <String>[];
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          (ref) => AuthNotifier(ApiService(baseUrl: '')),
        ),
        savedLoginsProvider.overrideWith(
          (ref) => _SeededSavedLogins(prefs, [_account('kuro')], calls),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DesktopLoginPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('account_switcher_button')));
    await tester.pumpAndSettle();
    // 唯一下拉项就是当前选中账号(index 0 == selectedIndex 0);
    // 文本与切换器标签重复,菜单项在 overlay 中后渲染,取 .last
    await tester.tap(find.text('kuro@$_server').last);
    await tester.pumpAndSettle();

    // switchTo 会 no-op,loginWith 必须真的发起登录
    expect(calls, ['login:kuro/pw']);
  });

  testWidgets('错误提示行:登录失败显示后端错误信息,成功前不显示', (tester) async {
    final prefs = await _mockPrefs();
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((ref) => _FailingAuth()),
        savedLoginsProvider.overrideWith(
          (ref) => _SeededSavedLogins(prefs, [], []),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DesktopLoginPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('login_error_line')), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('login_server_field')),
      _server,
    );
    await tester.enterText(
      find.byKey(const ValueKey('login_username_field')),
      'kuro',
    );
    await tester.enterText(
      find.byKey(const ValueKey('login_password_field')),
      'wrong-pw',
    );
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('login_error_line')), findsOneWidget);
    expect(find.text('用户名或密码错误'), findsOneWidget);
  });

  testWidgets('配对码绑定:对话框含配对码/Agent ID 输入,空输入内联提示不发网络', (tester) async {
    final prefs = await _mockPrefs();
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          (ref) => AuthNotifier(ApiService(baseUrl: '')),
        ),
        savedLoginsProvider.overrideWith(
          (ref) => _SeededSavedLogins(prefs, [], []),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: DesktopLoginPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('配对码绑定'));
    await tester.pumpAndSettle();

    expect(find.text('配对码'), findsOneWidget);
    expect(find.text('Agent ID'), findsOneWidget);

    await tester.tap(find.text('绑定'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pair_error_line')), findsOneWidget);
    expect(find.text('请填写完整'), findsOneWidget);
  });
}
