import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/models/account_mark.dart';
import 'package:app/pages/select_account_page.dart';
import 'package:app/providers/saved_logins_provider.dart';
import 'package:app/utils/secure_storage.dart';

void main() {
  late ProviderContainer container;
  late SavedLoginsNotifier notifier;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorage(deviceId: 'test-device');
    notifier = SavedLoginsNotifier(
      prefs: prefs,
      storage: storage,
      onBaseUrlChange: (_) {},
      onLogout: ({bool silent = false}) async {},
      onLogin: (u, p) async {},
      onSwitchingChange: (_) {},
    );
    await notifier.add('http://x', 'u1', 'p1');
    await notifier.add('http://y', 'u2', 'p2');
    container = ProviderContainer(
      overrides: [
        savedLoginsProvider.overrideWith((ref) => notifier),
      ],
    );
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // SelectAccountPage 内部用 context.pop 退出，需要 GoRouter 在树上且
    // 当前页是 push 进来的（go 不行，pop 会抛 "nothing to pop"）。
    // 故 initialLocation = '/'（占位页），pumpWidget 后 push '/select-account'。
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const SizedBox.shrink()),
        GoRoute(
            path: '/select-account',
            builder: (_, __) => const SelectAccountPage()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    router.push('/select-account');
    await tester.pumpAndSettle();
  }

  testWidgets('渲染所有卡片', (tester) async {
    await pumpPage(tester);
    expect(find.text('http://x'), findsOneWidget);
    expect(find.text('http://y'), findsOneWidget);
    expect(find.text('u1 @ http://x'), findsOneWidget);
    expect(find.text('u2 @ http://y'), findsOneWidget);
  });

  testWidgets('点卡片触发 switchTo 静默登录', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('http://x'));
    await tester.pumpAndSettle();
    // switchTo 成功后 selectedIndex 指向所点账号
    expect(notifier.state.selectedIndex, 0);
  });

  testWidgets('切换中显示 loading 遮罩', (tester) async {
    // 用延迟 onLogin 让切换过程可观察
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorage(deviceId: 'test-device');
    final slowNotifier = SavedLoginsNotifier(
      prefs: prefs,
      storage: storage,
      onBaseUrlChange: (_) {},
      onLogout: ({bool silent = false}) async {},
      onLogin: (u, p) async {
        await Future.delayed(const Duration(milliseconds: 100));
      },
      onSwitchingChange: (_) {},
    );
    await slowNotifier.add('http://x', 'u1', 'p1');
    await slowNotifier.add('http://y', 'u2', 'p2');
    slowNotifier.select(0); // 让 http://y(非当前)可点
    final c = ProviderContainer(
      overrides: [savedLoginsProvider.overrideWith((ref) => slowNotifier)],
    );
    addTearDown(c.dispose);
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const SizedBox.shrink()),
        GoRoute(
            path: '/select-account',
            builder: (_, __) => const SelectAccountPage()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();
    router.push('/select-account');
    await tester.pumpAndSettle();
    await tester.tap(find.text('http://y'));
    await tester.pump(); // 让 onTap 回调 + setState 执行
    await tester.pump(const Duration(milliseconds: 10)); // 渲染遮罩(onLogin 仍在延迟中)
    expect(find.text('登录中…'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('点删除按钮弹确认 dialog', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('delete_0')));
    await tester.pumpAndSettle();
    // dialog 标题 + 内容都含「确认删除」,用内容文本精确匹配
    expect(find.text('确认删除 u1 @ http://x?'), findsOneWidget);
  });

  testWidgets('确认删除后卡片消失', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('delete_0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('http://x'), findsNothing);
    expect(find.text('http://y'), findsOneWidget);
  });

  testWidgets('点编辑按钮弹编辑表单', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('edit_0')));
    await tester.pumpAndSettle();
    expect(find.text('编辑账号'), findsOneWidget);
  });

  testWidgets('点添加按钮弹新增表单', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('添加服务器'));
    await tester.pumpAndSettle();
    expect(find.text('添加账号'), findsOneWidget);
  });

  testWidgets('空列表显示提示文案', (tester) async {
    await notifier.remove(0);
    await notifier.remove(0);
    await pumpPage(tester);
    expect(find.textContaining('暂无记录'), findsOneWidget);
  });

  testWidgets('编辑 dialog 含 label 与标记编辑器', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('edit_0')));
    await tester.pumpAndSettle();
    expect(find.text('编辑账号'), findsOneWidget);
    expect(find.text('备注名(可选)'), findsOneWidget);
    expect(find.text('颜色标记'), findsOneWidget);
    expect(find.byKey(const ValueKey('palette_0')), findsOneWidget);
  });

  testWidgets('编辑后保存 label', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('edit_0')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('label_field')), '我的公司服');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(notifier.state.logins[0].label, '我的公司服');
  });

  testWidgets('选择颜色后保存 mark', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('edit_0')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('palette_2')));
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(notifier.state.logins[0].mark?.colorIndex, 2);
  });

  testWidgets('卡片展示 label 主标题与 emoji(有标记时)', (tester) async {
    // 直接给已存账号补 label + emoji,验证列表卡片展示同步
    await notifier.edit(
      0,
      label: '公司正式服',
      mark: const AccountMark(colorIndex: 2, emoji: '🟢'),
    );
    await pumpPage(tester);
    // label 作主标题
    expect(find.text('公司正式服'), findsOneWidget);
    // emoji 作 leading icon
    expect(find.text('🟢'), findsOneWidget);
    // 副标题仍含 server
    expect(find.text('u1 @ http://x'), findsOneWidget);
  });

  testWidgets('无 label 时主标题回退 server', (tester) async {
    await pumpPage(tester);
    // setUp 的账号无 label,主标题应是 server 本身
    expect(find.text('http://x'), findsOneWidget);
    expect(find.text('http://y'), findsOneWidget);
  });
}
