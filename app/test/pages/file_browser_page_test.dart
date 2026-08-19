import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:app/pages/chat/file_browser_page.dart';
import 'package:app/pages/chat/file_preview_page.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/file_browser_provider.dart';
import 'package:wanling_core/services/api_service.dart';

class _MockApi extends Mock implements ApiService {}

void main() {
  late _MockApi api;

  setUp(() {
    api = _MockApi();
  });

  testWidgets('首次渲染 → loading', (tester) async {
    when(() => api.rpc(any(), 'file.list', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'root': '/proj', 'path': '.',
              'entries': <Map<String, dynamic>>[],
              'truncated': false,
            });

    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: FileBrowserPage(agentId: 'a', convId: 'c')),
    ));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('RPC 返 1 目录 + 2 文件 → 渲染 3 tile + 分组标题', (tester) async {
    when(() => api.rpc(any(), 'file.list', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'root': '/proj', 'path': '.',
              'entries': [
                {'name': 'src', 'type': 'dir', 'size': 0},
                {'name': 'README.md', 'type': 'file', 'size': 100},
                {'name': 'logo.png', 'type': 'file', 'size': 2048},
              ],
              'truncated': false,
            });

    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: FileBrowserPage(agentId: 'a', convId: 'c')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('src'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.text('logo.png'), findsOneWidget);
    // 文件大小副标题(README.md = 100 B)
    expect(find.text('100 B'), findsOneWidget);
    // logo.png = 2048 B → 2.0 KB
    expect(find.text('2.0 KB'), findsOneWidget);
  });

  testWidgets('点目录 → 切换到子目录内容(同页)', (tester) async {
    when(() => api.rpc(any(), 'file.list', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((invocation) async {
      final params = invocation.positionalArguments[2] as Map<String, dynamic>;
      final path = params['path'] as String?;
      if (path == '.') {
        return {
          'root': '/proj', 'path': '.',
          'entries': [{'name': 'src', 'type': 'dir', 'size': 0}],
          'truncated': false,
        };
      }
      return {
        'root': '/proj', 'path': path,
        'entries': [{'name': 'main.go', 'type': 'file', 'size': 50}],
        'truncated': false,
      };
    });

    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: FileBrowserPage(agentId: 'a', convId: 'c')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('src'));
    await tester.pumpAndSettle();

    expect(find.text('main.go'), findsOneWidget);
  });

  testWidgets('点文件 → push FilePreviewPage', (tester) async {
    when(() => api.rpc(any(), 'file.list', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'root': '/proj', 'path': '.',
              'entries': [{'name': 'README.md', 'type': 'file', 'size': 100}],
              'truncated': false,
            });
    when(() => api.rpc(any(), 'file.read', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
          'path': 'README.md', 'type': 'text', 'mime': 'text/markdown',
          'size': 100, 'content': 'hello', 'truncated': false,
        });

    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: FileBrowserPage(agentId: 'a', convId: 'c')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('README.md'));
    await tester.pumpAndSettle();

    expect(find.byType(FilePreviewPage), findsOneWidget);
  });

  testWidgets('cwd 为绝对路径 → 不传给 file.list,初始 currentPath = "."', (tester) async {
    // 回归保护:cwd 是 server 端 session.directory 绝对路径(如 /home/u/proj),
    // 但 file.list 的 path 字段期望相对路径。
    // cwd 仅用于 AppBar 标题,绝不传给 popTo/loadDirectory,否则会拼出
    // /home/u/proj//home/u/proj/x 导致 file.read 失败。
    final captured = <String>[];
    when(() => api.rpc(any(), 'file.list', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((invocation) async {
      final params = invocation.positionalArguments[2] as Map<String, dynamic>;
      captured.add(params['path'] as String? ?? '(missing)');
      return {
        'root': '/home/u/proj', 'path': '.',
        'entries': <Map<String, dynamic>>[], 'truncated': false,
      };
    });

    final container =
        ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: FileBrowserPage(
          agentId: 'a',
          convId: 'c',
          cwd: '/home/u/proj',
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(captured, ['.']);
    final notifier = container.read(
      fileBrowserProvider(const (agentId: 'a', convId: 'c')).notifier,
    );
    expect(notifier.state.currentPath, '.');
    expect(notifier.state.pathStack, isEmpty);
  });
}
