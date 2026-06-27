import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    expect(find.text('账号: u1'), findsOneWidget);
    expect(find.text('账号: u2'), findsOneWidget);
  });

  testWidgets('点卡片触发 select', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('http://x'));
    await tester.pumpAndSettle();
    expect(notifier.state.selectedIndex, 0);
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
}
