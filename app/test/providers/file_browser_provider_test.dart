import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:app/models/file_entry.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/file_browser_provider.dart';
import 'package:app/services/api_service.dart';

class _MockApi extends Mock implements ApiService {}

void main() {
  late _MockApi api;

  setUp(() {
    api = _MockApi();
  });

  ProviderContainer _makeContainer() {
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    return c;
  }

  group('FileBrowserNotifier 目录导航', () {
    setUp(() {
      // provider 构造时触发 loadDirectory('.'),需 stub
      when(() => api.rpc(any(), 'file.list', any(),
              timeoutMs: any(named: 'timeoutMs')))
          .thenAnswer((inv) async {
        final params = inv.positionalArguments[2] as Map<String, dynamic>;
        return {
          'root': '/proj', 'path': params['path'] as String? ?? '.',
          'entries': <Map<String, dynamic>>[], 'truncated': false,
        };
      });
    });

    test('loadDirectory 设置 currentPath', () async {
      final container = _makeContainer();
      final notifier = container.read(
        fileBrowserProvider(const (agentId: 'a', convId: 'c')).notifier,
      );
      await notifier.loadDirectory('src/components');

      expect(notifier.state.currentPath, 'src/components');
    });

    test('enterDirectory 累积 pathStack + goUp 回溯', () async {
      final container = _makeContainer();
      final notifier = container.read(
        fileBrowserProvider(const (agentId: 'a', convId: 'c')).notifier,
      );

      await notifier.enterDirectory('src');
      expect(notifier.state.pathStack, ['.']);
      expect(notifier.state.currentPath, 'src');

      await notifier.enterDirectory('rpc');
      expect(notifier.state.pathStack, ['.', 'src']);
      expect(notifier.state.currentPath, 'src/rpc');

      await notifier.goUp();
      expect(notifier.state.currentPath, 'src');
      expect(notifier.state.pathStack, ['.']);
    });

    test('popTo 子目录 → 预填 pathStack', () async {
      final container = _makeContainer();
      final notifier = container.read(
        fileBrowserProvider(const (agentId: 'a', convId: 'c')).notifier,
      );

      await notifier.popTo('src/components');

      expect(notifier.state.currentPath, 'src/components');
      expect(notifier.state.pathStack, ['.', 'src']);
    });

    test('popTo(".") → 清空 pathStack + currentPath 回到 "."', () async {
      final container = _makeContainer();
      final notifier = container.read(
        fileBrowserProvider(const (agentId: 'a', convId: 'c')).notifier,
      );

      await notifier.enterDirectory('src');
      await notifier.enterDirectory('rpc');
      expect(notifier.state.pathStack, ['.', 'src']);

      await notifier.popTo('.');

      expect(notifier.state.currentPath, '.');
      expect(notifier.state.pathStack, isEmpty);
    });
  });

  group('FileBrowserNotifier loadFileContent', () {
    setUp(() {
      when(() => api.rpc(any(), 'file.list', any(),
              timeoutMs: any(named: 'timeoutMs')))
          .thenAnswer((_) async => {
                'root': '/proj', 'path': '.',
                'entries': <Map<String, dynamic>>[],
                'truncated': false,
              });
    });

    test('loadFileContent → previewContent 为 data', () async {
      when(() => api.rpc(any(), 'file.read', any(),
              timeoutMs: any(named: 'timeoutMs')))
          .thenAnswer((_) async => {
                'path': 'a.txt', 'type': 'text', 'mime': 'text/plain',
                'size': 5, 'content': 'hello', 'truncated': false,
              });

      final container = _makeContainer();
      final notifier = container.read(
        fileBrowserProvider(const (agentId: 'a', convId: 'c')).notifier,
      );

      const entry = FileEntry(name: 'a.txt', type: 'file', size: 5);
      await notifier.loadFileContent(entry);

      expect(notifier.state.previewContent?.value?.content, 'hello');
    });

    test('clearFileContent → previewContent 置 null', () async {
      final container = _makeContainer();
      final notifier = container.read(
        fileBrowserProvider(const (agentId: 'a', convId: 'c')).notifier,
      );

      notifier.clearFileContent();
      expect(notifier.state.previewContent, isNull);
    });

    test('loadFileContent RPC 抛错 → previewContent 为 error', () async {
      when(() => api.rpc(any(), 'file.read', any(),
              timeoutMs: any(named: 'timeoutMs')))
          .thenThrow(Exception('network down'));

      final container = _makeContainer();
      final notifier = container.read(
        fileBrowserProvider(const (agentId: 'a', convId: 'c')).notifier,
      );

      const entry = FileEntry(name: 'x.txt', type: 'file', size: 5);
      await notifier.loadFileContent(entry);

      expect(notifier.state.previewContent?.hasError, isTrue);
    });
  });
}
