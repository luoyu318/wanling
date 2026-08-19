import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';

import 'package:wanling_core/models/file_entry.dart';
import 'package:app/pages/chat/file_preview_page.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/file_browser_provider.dart';
import 'package:wanling_core/services/api_service.dart';

class _MockApi extends Mock implements ApiService {}

void main() {
  late _MockApi api;

  setUp(() {
    api = _MockApi();
    // file.list 在 provider 构造时触发,先 stub 掉
    when(() => api.rpc(any(), 'file.list', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'root': '/proj', 'path': '.',
              'entries': <Map<String, dynamic>>[],
              'truncated': false,
            });
  });

  testWidgets('文本文件预览 → 显示文件名 + 内容', (tester) async {
    when(() => api.rpc(any(), 'file.read', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'path': 'a.txt', 'type': 'text', 'mime': 'text/plain',
              'size': 5, 'content': 'hello world', 'truncated': false,
            });

    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: FilePreviewPage(
          browserKey: const (agentId: 'a', convId: 'c'),
          entry: const FileEntry(name: 'a.txt', type: 'file', size: 5),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('a.txt'), findsWidgets);
    expect(
      find.byWidgetPredicate((w) =>
          w is RichText &&
          (w.text as TextSpan).toPlainText().contains('hello world')),
      findsOneWidget,
    );
  });

  testWidgets('加载中 → CircularProgressIndicator', (tester) async {
    when(() => api.rpc(any(), 'file.read', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async {
      await Future.delayed(const Duration(seconds: 1));
      return {
        'path': 'a.txt', 'type': 'text', 'mime': 'text/plain',
        'size': 5, 'content': 'hello', 'truncated': false,
      };
    });

    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: FilePreviewPage(
          browserKey: const (agentId: 'a', convId: 'c'),
          entry: const FileEntry(name: 'a.txt', type: 'file', size: 5),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('二进制文件 → 显示不支持预览', (tester) async {
    when(() => api.rpc(any(), 'file.read', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'path': 'app.db', 'type': 'binary', 'mime': 'application/octet-stream',
              'size': 1024, 'truncated': false,
            });

    final container = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: FilePreviewPage(
          browserKey: const (agentId: 'a', convId: 'c'),
          entry: const FileEntry(name: 'app.db', type: 'file', size: 1024, binary: true),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('该文件类型不支持预览'), findsOneWidget);
  });

  testWidgets('dispose → clearFileContent 清空 previewContent', (tester) async {
    when(() => api.rpc(any(), 'file.read', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'path': 'a.txt', 'type': 'text', 'mime': 'text/plain',
              'size': 5, 'content': 'hello', 'truncated': false,
            });

    final container =
        ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    const key = (agentId: 'a', convId: 'c');
    // 持有订阅防止 autoDispose 在预览页卸载后重建 provider(那会掩盖 clearFileContent 的效果)
    final sub = container.listen(fileBrowserProvider(key), (_, _) {});
    addTearDown(sub.close);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    ));

    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(navigator.push(MaterialPageRoute(
      builder: (_) => FilePreviewPage(
        browserKey: key,
        entry: const FileEntry(name: 'a.txt', type: 'file', size: 5),
      ),
    )));
    await tester.pumpAndSettle();

    final notifier = container.read(fileBrowserProvider(key).notifier);
    expect(notifier.state.previewContent?.value?.content, 'hello');

    // 退出预览页(scheduleMicrotask 在 dispose 中排队,pumpAndSettle 让微任务落地)
    navigator.pop();
    await tester.pumpAndSettle();

    expect(notifier.state.previewContent, isNull);
  });

  testWidgets('复制全文 → 弹统一提示条(非 SnackBar)', (tester) async {
    when(() => api.rpc(any(), 'file.read', any(),
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'path': 'a.txt', 'type': 'text', 'mime': 'text/plain',
              'size': 5, 'content': 'hello world', 'truncated': false,
            });

    final container =
        ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: FilePreviewPage(
          browserKey: (agentId: 'a', convId: 'c'),
          entry: FileEntry(name: 'a.txt', type: 'file', size: 5),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 点 AppBar 复制按钮
    await tester.tap(find.byIcon(Icons.content_copy));
    await tester.pump();

    // 统一提示条出现,且不是旧 SnackBar
    expect(find.text('已复制'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing,
        reason: '复制提示应走统一 AppSnackBar,而非 SnackBar');
  });
}
