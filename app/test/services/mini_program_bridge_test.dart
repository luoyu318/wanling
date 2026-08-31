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

  group('effectivePermissions', () {
    test('非 chat 权限直接生效,chat 权限须在授权集', () {
      final declared = {'wanling.api', 'wanling.chat.read', 'wanling.chat.share'};
      expect(effectivePermissions(declared, {}), {'wanling.api'});
      expect(effectivePermissions(declared, {'wanling.chat.read'}),
          {'wanling.api', 'wanling.chat.read'});
    });

    test('granted 中未 declared 的权限不生效', () {
      final declared = {'wanling.api', 'wanling.chat.read'};
      expect(
        effectivePermissions(declared,
            {'wanling.chat.read', 'wanling.chat.share', 'wanling.evil'}),
        {'wanling.api', 'wanling.chat.read'},
      );
    });
  });

  group('wanlingGetChatContext', () {
    test('有权限返回 conversation_id', () async {
      final b = MiniProgramBridge(
        permissions: const {'wanling.chat.read'},
        proxy: (_, _, _) async => null,
        onChatContext: () => 'conv-1',
      );
      final r = await b.handle('wanlingGetChatContext', const []);
      expect((r as Map)['ok'], isTrue);
      expect((r['data'] as Map)['conversation_id'], 'conv-1');
    });

    test('无权限拒绝且不触达 onChatContext', () async {
      var called = false;
      final b = MiniProgramBridge(
        permissions: const {},
        proxy: (_, _, _) async => null,
        onChatContext: () {
          called = true;
          return 'conv-1';
        },
      );
      final r = await b.handle('wanlingGetChatContext', const []);
      expect((r as Map)['ok'], isFalse);
      expect(r['error'], 'permission denied: wanling.chat.read');
      expect(called, isFalse);
    });

    test('onChatContext 返 null(未接会话) → ok:true data:null', () async {
      final b = MiniProgramBridge(
        permissions: const {'wanling.chat.read'},
        proxy: (_, _, _) async => null,
        onChatContext: () => null,
      );
      final r = await b.handle('wanlingGetChatContext', const []);
      expect((r as Map)['ok'], isTrue);
      expect(r['data'], isNull);
    });
  });

  group('wanlingShareToChat', () {
    test('无权限拒绝且不触达 onShare', () async {
      var called = false;
      final b = MiniProgramBridge(
        permissions: const {},
        proxy: (_, _, _) async => null,
        onShare: (_) async {
          called = true;
          return {'message_id': 'm1'};
        },
      );
      final r = await b.handle('wanlingShareToChat', [
        {'text': 'hi'}
      ]);
      expect((r as Map)['ok'], isFalse);
      expect(r['error'], 'permission denied: wanling.chat.share');
      expect(called, isFalse);
    });

    test('用户取消(onShare 返 null) → ok:false cancelled', () async {
      final b = MiniProgramBridge(
        permissions: const {'wanling.chat.share'},
        proxy: (_, _, _) async => null,
        onShare: (_) async => null,
      );
      final r = await b.handle('wanlingShareToChat', [
        {'text': 'hi'}
      ]);
      expect((r as Map)['ok'], isFalse);
      expect(r['error'], 'cancelled');
    });

    test('成功透传 onShare 返回值与 payload', () async {
      Map<String, dynamic>? seenPayload;
      final b = MiniProgramBridge(
        permissions: const {'wanling.chat.share'},
        proxy: (_, _, _) async => null,
        onShare: (payload) async {
          seenPayload = payload;
          return {'message_id': 'm1'};
        },
      );
      final r = await b.handle('wanlingShareToChat', [
        {'text': 'hi'}
      ]);
      expect((r as Map)['ok'], isTrue);
      expect((r['data'] as Map)['message_id'], 'm1');
      expect(seenPayload, {'text': 'hi'});
    });

    test('有权限但 onShare 未注入 → share unavailable', () async {
      final b = MiniProgramBridge(
        permissions: const {'wanling.chat.share'},
        proxy: (_, _, _) async => null,
      );
      final r = await b.handle('wanlingShareToChat', const []);
      expect((r as Map)['ok'], isFalse);
      expect(r['error'], 'share unavailable');
    });

    test('onShare 抛异常 → 外层 catch 转 ok:false envelope', () async {
      final b = MiniProgramBridge(
        permissions: const {'wanling.chat.share'},
        proxy: (_, _, _) async => null,
        onShare: (_) async => throw Exception('share boom'),
      );
      final r = await b.handle('wanlingShareToChat', const []);
      expect((r as Map)['ok'], isFalse);
      expect((r['error'] as String), contains('share boom'));
    });
  });
}
