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

  test('/api/me 精确命中 → 拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/me', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    final err = r['error'] as Map;
    expect(err['code'], -32091);
    expect(err['message'], '身份信息请使用 wanlingGetProfile');
    expect(called, isFalse);
  });

  test('/api/users/me 真实身份端点精确命中 → 拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/users/me', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    final err = r['error'] as Map;
    expect(err['code'], -32091);
    expect(err['message'], '身份信息请使用 wanlingGetProfile');
    expect(called, isFalse);
  });

  test('/api/users/me 带 query 变体 → 同样拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/users/me?x=1', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    final err = r['error'] as Map;
    expect(err['code'], -32091);
    expect(called, isFalse);
  });

  test('/api/me 带 query 变体 → 同样拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/me?x=1', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    final err = r['error'] as Map;
    expect(err['code'], -32091);
    expect(called, isFalse);
  });

  test('/api/admin/mini-programs 前缀命中 → 拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/admin/mini-programs', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    final err = r['error'] as Map;
    expect(err['code'], -32091);
    expect(err['message'], '身份信息请使用 wanlingGetProfile');
    expect(called, isFalse);
  });

  test('普通路径 /api/conversations 放行照旧', () async {
    var calls = 0;
    String? seenPath;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (path, _, _) async {
        calls++;
        seenPath = path;
        return {'id': 'c1'};
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/conversations', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isTrue);
    expect((r['data'] as Map)['id'], 'c1');
    expect(calls, 1);
    expect(seenPath, '/api/conversations');
  });

  test('/api/meX 精确匹配不误伤 → 放行', () async {
    var calls = 0;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        calls++;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/meX', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isTrue);
    expect(calls, 1);
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

  group('openPage', () {
    test('无 wanling.nav 权限 → 拒绝且不触达回调', () async {
      var called = false;
      final b = MiniProgramBridge(
        permissions: const {},
        proxy: (_, _, _) async => null,
        onOpenPage: (_) => called = true,
      );
      final r = await b.handle('wanlingOpenPage', [
        {'page': 'home'}
      ]);
      expect((r as Map)['ok'], isFalse);
      expect(called, isFalse);
    });

    test('白名单外页面 → 拒绝', () async {
      var called = false;
      final b = MiniProgramBridge(
        permissions: const {'wanling.nav'},
        proxy: (_, _, _) async => null,
        onOpenPage: (_) => called = true,
      );
      final r = await b.handle('wanlingOpenPage', [
        {'page': 'settings'}
      ]);
      expect((r as Map)['ok'], isFalse);
      expect(called, isFalse);
    });

    test('agentDetail 非法 agentId → 拒绝', () async {
      var called = false;
      final b = MiniProgramBridge(
        permissions: const {'wanling.nav'},
        proxy: (_, _, _) async => null,
        onOpenPage: (_) => called = true,
      );
      final r = await b.handle('wanlingOpenPage', [
        {'page': 'agentDetail', 'params': {'agentId': '../../evil'}}
      ]);
      expect((r as Map)['ok'], isFalse);
      expect(called, isFalse);
    });

    test('合法 agentDetail/home/miniPrograms → 透传 route 描述', () async {
      Map<String, dynamic>? seen;
      final b = MiniProgramBridge(
        permissions: const {'wanling.nav'},
        proxy: (_, _, _) async => null,
        onOpenPage: (route) => seen = route,
      );
      final r1 = await b.handle('wanlingOpenPage', [
        {'page': 'agentDetail', 'params': {'agentId': '38a7202f-131d-4067-b303-063a8a0b1429'}}
      ]);
      expect((r1 as Map)['ok'], isTrue);
      expect(seen, {'route': 'agentDetail', 'agent_id': '38a7202f-131d-4067-b303-063a8a0b1429'});

      final r2 = await b.handle('wanlingOpenPage', [
        {'page': 'home'}
      ]);
      expect((r2 as Map)['data'], {'route': 'home'});

      final r3 = await b.handle('wanlingOpenPage', [
        {'page': 'miniPrograms'}
      ]);
      expect((r3 as Map)['data'], {'route': 'miniPrograms'});
    });
  });
}
