import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}