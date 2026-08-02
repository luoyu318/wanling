import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/services/api_service.dart';
import 'package:app/widgets/directory_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;

  setUp(() {
    api = MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [apiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<void> pumpSheet(
    WidgetTester tester,
    ProviderContainer container, {
    String? defaultDirectory,
    void Function(DirectoryPickerResult? result)? onResult,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () async {
                  final r = await showDirectoryPickerSheet(
                    ctx,
                    agentId: 'test-agent',
                    defaultDirectory: defaultDirectory,
                  );
                  onResult?.call(r);
                },
                child: const Text('trigger'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
  }

  testWidgets('渲染 project.list 结果(名字 + 路径)', (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {
              'projects': [
                {'path': '/a', 'name': 'A'},
                {'path': '/b', 'name': 'B'},
              ],
            });

    await pumpSheet(tester, makeContainer());

    expect(find.text('选择工作目录'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('/a'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('/b'), findsOneWidget);
  });

  testWidgets('点项目卡片 → 选中态更新但不关闭；点确认 → 返该路径(cancelled=false)',
      (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {
              'projects': [
                {'path': '/a', 'name': 'A'},
              ],
            });

    DirectoryPickerResult? result =
        (directory: 'sentinel', cancelled: true);
    await pumpSheet(tester, makeContainer(), onResult: (r) => result = r);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();

    expect(find.text('选择工作目录'), findsOneWidget);
    expect(result, (directory: 'sentinel', cancelled: true));

    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(result, (directory: '/a', cancelled: false));
  });

  testWidgets('rpc 失败 → 显示错误 + 重试按钮', (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenThrow(Exception('network down'));

    await pumpSheet(tester, makeContainer());

    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('空列表 → 显示"暂无项目"提示', (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {'projects': []});

    await pumpSheet(tester, makeContainer());

    expect(find.text('暂无项目'), findsOneWidget);
  });

  testWidgets('点 X 关闭 → 返 cancelled=true', (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {'projects': []});

    DirectoryPickerResult? result =
        (directory: 'sentinel', cancelled: false);
    await pumpSheet(tester, makeContainer(), onResult: (r) => result = r);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(result, (directory: null, cancelled: true));
  });

  testWidgets('点 "不选(用默认)" → 返 directory=null, cancelled=false', (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {'projects': []});

    DirectoryPickerResult? result =
        (directory: 'sentinel', cancelled: true);
    await pumpSheet(tester, makeContainer(), onResult: (r) => result = r);

    await tester.tap(find.text('不选(用默认)'));
    await tester.pumpAndSettle();

    expect(result, (directory: null, cancelled: false));
  });

  testWidgets('defaultDirectory 预选 → 不点卡片直接确认返该路径', (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {
              'projects': [
                {'path': '/a', 'name': 'A'},
                {'path': '/b', 'name': 'B'},
              ],
            });

    DirectoryPickerResult? result =
        (directory: 'sentinel', cancelled: true);
    await pumpSheet(
      tester,
      makeContainer(),
      defaultDirectory: '/b',
      onResult: (r) => result = r,
    );

    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(result, (directory: '/b', cancelled: false));
  });

  testWidgets('defaultDirectory 对应卡片高亮(背景 #E8F0FE),其他卡片为默认底色',
      (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {
              'projects': [
                {'path': '/a', 'name': 'A'},
                {'path': '/b', 'name': 'B'},
              ],
            });

    await pumpSheet(tester, makeContainer(), defaultDirectory: '/b');

    final selectedMaterialFinder = find.byWidgetPredicate(
      (w) => w is Material && w.color == const Color(0xFFE8F0FE),
    );
    expect(selectedMaterialFinder, findsOneWidget);
    expect(
      find.descendant(of: selectedMaterialFinder, matching: find.text('B')),
      findsOneWidget,
    );

    final unselectedMaterialFinder = find.byWidgetPredicate(
      (w) => w is Material && w.color == const Color(0xFFF5F5F5),
    );
    expect(unselectedMaterialFinder, findsOneWidget);
    expect(
      find.descendant(of: unselectedMaterialFinder, matching: find.text('A')),
      findsOneWidget,
    );
  });

  testWidgets('无 defaultDirectory 且未点卡片 → 确认按钮禁用', (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {
              'projects': [
                {'path': '/a', 'name': 'A'},
              ],
            });

    await pumpSheet(tester, makeContainer());

    final confirmButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('确认'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(confirmButton.onPressed, isNull);
  });

  testWidgets('点卡片后切换选中 → 之前高亮卡片恢复默认底色', (tester) async {
    when(() => api.rpc(
            'test-agent', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {
              'projects': [
                {'path': '/a', 'name': 'A'},
                {'path': '/b', 'name': 'B'},
              ],
            });

    await pumpSheet(tester, makeContainer(), defaultDirectory: '/b');

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();

    final selectedMaterialFinder = find.byWidgetPredicate(
      (w) => w is Material && w.color == const Color(0xFFE8F0FE),
    );
    expect(selectedMaterialFinder, findsOneWidget);
    expect(
      find.descendant(of: selectedMaterialFinder, matching: find.text('A')),
      findsOneWidget,
    );

    final unselectedMaterialFinder = find.byWidgetPredicate(
      (w) => w is Material && w.color == const Color(0xFFF5F5F5),
    );
    expect(unselectedMaterialFinder, findsOneWidget);
    expect(
      find.descendant(of: unselectedMaterialFinder, matching: find.text('B')),
      findsOneWidget,
    );
  });
}
