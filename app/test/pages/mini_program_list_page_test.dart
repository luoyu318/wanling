import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/mini_programs_provider.dart';

import 'package:app/pages/mini_program_list_page.dart';

void main() {
  Widget build(ProviderContainer container) =>
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: MiniProgramListPage()),
      );

  testWidgets('分组渲染:published 进公共库,private 进我的', (tester) async {
    final container = ProviderContainer(overrides: [
      miniProgramsProvider.overrideWith((ref) async => [
            const MiniProgramInfo(
              id: '1', appid: 'pub', ownerId: 'o1', name: '公共小程序',
              version: 1, status: 'published', sha256: 'x', size: 1,
            ),
            const MiniProgramInfo(
              id: '2', appid: 'mine', ownerId: 'me', name: '我的小程序',
              version: 1, status: 'private', sha256: 'x', size: 1,
            ),
          ]),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(build(container));
    await tester.pumpAndSettle();

    expect(find.text('公共库'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('公共小程序'), findsOneWidget);
    expect(find.text('我的小程序'), findsOneWidget);
  });

  testWidgets('空列表展示空态', (tester) async {
    final container = ProviderContainer(overrides: [
      miniProgramsProvider.overrideWith((ref) async => const []),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(build(container));
    await tester.pumpAndSettle();

    expect(find.text('暂无小程序'), findsOneWidget);
  });

  testWidgets('删除不可逆:先弹确认框,取消不执行,确认后才触发 service',
      (tester) async {
    // TokenVault 注入登录态,否则 delete 走到 token 空校验即失败。
    FlutterSecureStorage.setMockInitialValues({'access_token': 't'});
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(overrides: [
      miniProgramsProvider.overrideWith((ref) async => const [
            MiniProgramInfo(
              id: '2', appid: 'mine', ownerId: 'me', name: '我的小程序',
              version: 1, status: 'private', sha256: 'x', size: 1,
            ),
          ]),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(build(container));
    await tester.pumpAndSettle();

    // 点删除 → 先弹确认框,未触发 service(无失败反馈)。
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('确认删除小程序?'), findsOneWidget);
    expect(find.textContaining('删除失败'), findsNothing);

    // 取消 → 不执行删除,条目保留。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除小程序?'), findsNothing);
    expect(find.text('我的小程序'), findsOneWidget);
    expect(find.textContaining('删除失败'), findsNothing);

    // 确认 → 才调 service(测试环境 HTTP 被 mock 成 400 → 失败 SnackBar)。
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除失败'), findsOneWidget);
  });
}
