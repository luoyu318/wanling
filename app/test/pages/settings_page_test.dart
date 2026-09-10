// SettingsPage 测试:分组渲染/四项文案/开关切换落盘。
// harness 照 account_sidebar_test:mock prefs + authProvider(u1) +
// sharedPrefsProvider 注入;本页无 package_info 依赖(版本号在「关于」)。
// 导航项不做 tap 断言(裸 MaterialApp 无 GoRouter scope),导航跳转未做
// 自动化覆盖,真机验收兜底。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart'
    show sharedPrefsProvider;
import 'package:wanling_core/services/api_service.dart';
import 'package:app/pages/settings_page.dart';

void main() {
  late ProviderContainer container;

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsPage()),
    ));
    await tester.pumpAndSettle();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final authNotifier = AuthNotifier(ApiService(baseUrl: 'http://test.local'));
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
    container = ProviderContainer(overrides: [
      authProvider.overrideWith((ref) => authNotifier),
      sharedPrefsProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);
  });

  testWidgets('分组标题与四项文案渲染', (tester) async {
    await pumpSettings(tester);
    expect(find.text('账号'), findsOneWidget);
    expect(find.text('通知与偏好'), findsOneWidget);
    expect(find.text('编辑资料'), findsOneWidget);
    expect(find.text('修改密码'), findsOneWidget);
    expect(find.text('通知与后台'), findsOneWidget);
    expect(find.text('自动弹出审批/问答'), findsOneWidget);
    expect(find.text('关闭后卡片仍在会话内，需进入会话处理'), findsOneWidget);
  });

  testWidgets('开关:默认开,整行点击关闭并落盘,开关本体恢复', (tester) async {
    await pumpSettings(tester);
    final finder = find.byKey(const ValueKey('inbox-auto-popup-switch'));
    expect(tester.widget<Switch>(finder).value, isTrue);

    await tester.tap(find.text('自动弹出审批/问答'));
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(finder).value, isFalse);
    expect((await SharedPreferences.getInstance())
        .getBool('inbox_auto_popup_u1'), isFalse);

    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(finder).value, isTrue);
  });
}
