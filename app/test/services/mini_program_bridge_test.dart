import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/mini_program_bridge.dart';

void main() {
  test('无 wanling.api 权限 → request 拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/agent-types', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect(called, isFalse);
  });

  test('非 /api/ 路径 → 拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': 'https://evil.example.com/x', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect(called, isFalse);
  });

  test('/api/../agent-types 归一化越出白名单 → 拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/../agent-types', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect(called, isFalse);
  });

  test('/api/./agent-types 归一化后仍在白名单 → 放行并透传归一化路径', () async {
    String? seenPath;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (path, _, _) async {
        seenPath = path;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/./agent-types', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isTrue);
    expect(seenPath, '/api/agent-types');
  });

  test('合法调用透传 proxy 结果', () async {
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (path, method, body) async {
        expect(path, '/api/agent-types');
        expect(method, 'GET');
        return [
          {'type': 'hermes'}
        ];
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/agent-types', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isTrue);
    expect((r['data'] as List), hasLength(1));
  });

  test('proxy 抛异常 → ok:false 带错误信息(不向上抛)', () async {
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async => throw Exception('boom'),
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/agent-types', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect((r['error'] as String), isNotEmpty);
  });

  test('close 回调触发', () async {
    var closed = false;
    final b = MiniProgramBridge(
      permissions: const {},
      proxy: (_, _, _) async => null,
      onClose: () => closed = true,
    );
    await b.handle('wanlingClose', const []);
    expect(closed, isTrue);
  });

  test('未知方法 → ok:false', () async {
    final b = MiniProgramBridge(
      permissions: const {},
      proxy: (_, _, _) async => null,
    );
    final r = await b.handle('wanlingEvil', const []);
    expect((r as Map)['ok'], isFalse);
  });
}