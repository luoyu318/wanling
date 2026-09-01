// 小程序审核页 widget 测试:三 Tab 分组渲染/发布操作(确认弹窗→API→invalidate)/
// 403 无权限兜底/非 403 错误重试。
// harness 对齐 mini_program_list_page_test:apiProvider 用 mocktail MockApi stub baseUrl,
// adminMiniProgramsProvider 整体 override(数据列表或抛 ApiException)。
import 'package:app/pages/admin_mini_program_page.dart';
import 'package:wanling_core/models/admin_mini_program_info.dart';
import 'package:wanling_core/providers/admin_mini_programs_provider.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/services/api_response.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements ApiService {}

AdminMiniProgramInfo _mp(String status, {String owner = 'kira'}) =>
    AdminMiniProgramInfo(
      id: 'id-$status',
      appid: 'app.$status',
      ownerUsername: owner,
      name: 'N-$status',
      version: 1,
      icon: '',
      permissions: const [],
      status: status,
      size: 1024,
    );

void main() {
  late MockApi api;
  setUp(() {
    api = MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
  });

  ProviderContainer makeContainer(List<AdminMiniProgramInfo> items) {
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      adminMiniProgramsProvider.overrideWith((ref) async => items),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  testWidgets('三 Tab 渲染:待审/已发布/已下架,条目进对应 Tab', (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: makeContainer([_mp('private'), _mp('published'), _mp('disabled')]),
      child: const MaterialApp(home: AdminMiniProgramPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('待审'), findsOneWidget);
    expect(find.text('已发布'), findsOneWidget);
    expect(find.text('已下架'), findsOneWidget);
    expect(find.text('N-private'), findsOneWidget);
  });

  testWidgets('发布操作:确认弹窗→确认→调 setMiniProgramStatus→invalidate 刷新',
      (tester) async {
    when(() => api.setMiniProgramStatus('id-private', 'published'))
        .thenAnswer((_) async {});
    await tester.pumpWidget(UncontrolledProviderScope(
      container: makeContainer([_mp('private')]),
      child: const MaterialApp(home: AdminMiniProgramPage()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    expect(find.text('确认发布？'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    verify(() => api.setMiniProgramStatus('id-private', 'published')).called(1);
  });

  testWidgets('403 → 页面提示无权限', (tester) async {
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      adminMiniProgramsProvider.overrideWith((ref) async =>
          throw ApiException('forbidden', 'denied', statusCode: 403)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c, child: const MaterialApp(home: AdminMiniProgramPage())));
    await tester.pumpAndSettle();
    expect(find.textContaining('无权限'), findsOneWidget);
  });

  testWidgets('非 403 错误 → 加载失败文案 + 重试按钮', (tester) async {
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      adminMiniProgramsProvider.overrideWith((ref) async =>
          throw ApiException('internal', 'boom', statusCode: 500)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c, child: const MaterialApp(home: AdminMiniProgramPage())));
    await tester.pumpAndSettle();
    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });
}
