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
    expect(r['error'], '-32091 身份信息请使用 wanlingGetProfile');
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
    expect(r['error'], '-32091 身份信息请使用 wanlingGetProfile');
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
    expect(r['error'], startsWith('-32091'));
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
    expect(r['error'], startsWith('-32091'));
    expect(called, isFalse);
  });

  test('/api/users/me/ 尾斜杠变体 → 拒绝且不触达 proxy(防 301 跟随绕过)', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/users/me/', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect(r['error'], '-32091 身份信息请使用 wanlingGetProfile');
    expect(called, isFalse);
  });

  test('/api/users/me// 双尾斜杠变体 → 拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/users/me//', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect(r['error'], startsWith('-32091'));
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
    expect(r['error'], '-32091 身份信息请使用 wanlingGetProfile');
    expect(called, isFalse);
  });

  test('/api/admin/ 自身折叠后前缀失配 → 补精确分支仍拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/admin/', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect(r['error'], startsWith('-32091'));
    expect(called, isFalse);
  });

  test('/api/admin// 双尾斜杠变体 → 拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/admin//', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect(r['error'], startsWith('-32091'));
    expect(called, isFalse);
  });

  test('/api/users/me%2F 编码斜杠变体 → 解码归一后拒绝且不触达 proxy(防 Go 解码 301 绕过)', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/users/me%2F', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect(r['error'], '-32091 身份信息请使用 wanlingGetProfile');
    expect(called, isFalse);
  });

  test('/api/users/me%252F 双编码 → 放行(两端单次解码语义对齐,双编码不构成拦截面)', () async {
    var calls = 0;
    String? seenPath;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (path, _, _) async {
        calls++;
        seenPath = path;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/users/me%252F', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isTrue);
    expect(calls, 1);
    // 透传原路径:dio 原样发 %252F,Go URL.Path 单次解码后为字面 %2F 而非 '/',
    // 无 301 绕过面;两侧解码次数对齐,拦截面只在单次编码变体
    expect(seenPath, '/api/users/me%252F');
  });

  test('/api/mini-programs/openid 直调自传 appid → 拒绝且不触达 proxy', () async {
    var called = false;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (_, _, _) async {
        called = true;
        return null;
      },
    );
    final r = await b.handle('wanlingRequest', [
      {'path': '/api/mini-programs/openid?appid=tracker', 'method': 'GET'}
    ]);
    expect((r as Map)['ok'], isFalse);
    expect(r['error'], '-32091 身份信息请使用 wanlingGetProfile');
    expect(called, isFalse);
  });

  test('/api/mini-programs/<id>/package 同前缀合法路径 → 放行不误伤', () async {
    var calls = 0;
    String? seenPath;
    final b = MiniProgramBridge(
      permissions: const {'wanling.api'},
      proxy: (path, _, _) async {
        calls++;
        seenPath = path;
        return {'version': '1'};
      },
    );
    final r = await b.handle('wanlingRequest', [
      {
        'path': '/api/mini-programs/c94a4aa1/package',
        'method': 'GET'
      }
    ]);
    expect((r as Map)['ok'], isTrue);
    expect((r['data'] as Map)['version'], '1');
    expect(calls, 1);
    expect(seenPath, '/api/mini-programs/c94a4aa1/package');
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

  group('wanlingGetProfile', () {
    test('KVS 已授权 → 直接返回数据,弹窗回调零调用', () async {
      var asked = 0;
      String? seenPath;
      final b = MiniProgramBridge(
        permissions: const {},
        proxy: (path, _, _) async {
          seenPath = path;
          return {'openid': 'o-123'};
        },
        appid: 'com.demo.app',
        nickname: '张三',
        avatarUrl: 'https://a/x.png',
        isProfileGranted: () async => true,
        requestProfilePermission: () async {
          asked++;
          return true;
        },
        persistProfileGrant: () async {},
      );
      final r = await b.handle('wanlingGetProfile', const []);
      expect((r as Map)['ok'], isTrue);
      expect(r['data'], {
        'openid': 'o-123',
        'nickname': '张三',
        'avatarUrl': 'https://a/x.png',
      });
      expect(asked, 0);
      expect(seenPath, '/api/mini-programs/openid?appid=com.demo.app');
    });

    test('未授权 → 拒绝 → -32090 且 KVS 无痕、不触达 proxy', () async {
      var persisted = 0;
      var fetched = false;
      final b = MiniProgramBridge(
        permissions: const {},
        proxy: (_, _, _) async {
          fetched = true;
          return null;
        },
        appid: 'com.demo.app',
        nickname: '张三',
        avatarUrl: null,
        isProfileGranted: () async => false,
        requestProfilePermission: () async => false,
        persistProfileGrant: () async => persisted++,
      );
      final r = await b.handle('wanlingGetProfile', const []);
      expect((r as Map)['ok'], isFalse);
      expect(r['error'], '-32090 用户未授权');
      expect(persisted, 0);
      expect(fetched, isFalse);
    });

    test('弹窗回调未注入(null) → 防御性视作拒绝 -32090', () async {
      final b = MiniProgramBridge(
        permissions: const {},
        proxy: (_, _, _) async => null,
        appid: 'com.demo.app',
        nickname: '张三',
        avatarUrl: null,
        isProfileGranted: () async => false,
      );
      final r = await b.handle('wanlingGetProfile', const []);
      expect((r as Map)['ok'], isFalse);
      expect(r['error'], startsWith('-32090'));
    });

    test('未授权 → 允许 → KVS 落痕 + 返回 {openid,nickname,avatarUrl}', () async {
      final kvs = <String>{};
      final b = MiniProgramBridge(
        permissions: const {},
        proxy: (_, _, _) async => {'openid': 'o-123'},
        appid: 'com.demo.app',
        nickname: '张三',
        avatarUrl: null,
        isProfileGranted: () async => kvs.contains('wanling.profile'),
        requestProfilePermission: () async => true,
        persistProfileGrant: () async => kvs.add('wanling.profile'),
      );
      final r = await b.handle('wanlingGetProfile', const []);
      expect((r as Map)['ok'], isTrue);
      expect((r['data'] as Map)['openid'], 'o-123');
      expect((r['data'] as Map)['nickname'], '张三');
      expect(kvs, {'wanling.profile'});
    });

    test('openid 端点失败 → 错误不静默;失败不缓存,恢复后已授权直返', () async {
      final kvs = <String>{};
      var calls = 0;
      var asked = 0;
      final b = MiniProgramBridge(
        permissions: const {},
        proxy: (_, _, _) async {
          calls++;
          if (calls == 1) throw Exception('openid endpoint boom');
          return {'openid': 'o-123'};
        },
        appid: 'com.demo.app',
        nickname: '张三',
        avatarUrl: null,
        isProfileGranted: () async => kvs.contains('wanling.profile'),
        requestProfilePermission: () async {
          asked++;
          return true;
        },
        persistProfileGrant: () async => kvs.add('wanling.profile'),
      );
      final r1 = await b.handle('wanlingGetProfile', const []);
      expect((r1 as Map)['ok'], isFalse);
      expect((r1['error'] as String), contains('openid endpoint boom'));
      final r2 = await b.handle('wanlingGetProfile', const []);
      expect((r2 as Map)['ok'], isTrue);
      expect((r2['data'] as Map)['openid'], 'o-123');
      expect(asked, 1);
    });

    test('appid 未注入 → -32091 不适用,不弹窗不触达 proxy', () async {
      var asked = 0;
      var fetched = false;
      final b = MiniProgramBridge(
        permissions: const {},
        proxy: (_, _, _) async {
          fetched = true;
          return null;
        },
        nickname: '张三',
        avatarUrl: null,
        isProfileGranted: () async => false,
        requestProfilePermission: () async {
          asked++;
          return true;
        },
      );
      final r = await b.handle('wanlingGetProfile', const []);
      expect((r as Map)['ok'], isFalse);
      expect(r['error'], startsWith('-32091'));
      expect(asked, 0);
      expect(fetched, isFalse);
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

  group('normalizeBridgeError(出口规范化,error 恒为 String)', () {
    test('对象 {code, message} → "-<code> <message>"(code 语义保留在前缀)', () {
      expect(normalizeBridgeError({
        'code': -32090,
        'message': '用户未授权',
      }), '-32090 用户未授权');
    });

    test('String 原样透传(传输异常/权限拒绝描述)', () {
      expect(normalizeBridgeError('permission denied: wanling.api'),
          'permission denied: wanling.api');
    });

    test('带 code 无 message → "-<code>"', () {
      expect(normalizeBridgeError({'code': -32091}), '-32091');
    });

    test('仅 message 无 code → message', () {
      expect(normalizeBridgeError({'message': '仅消息'}), '仅消息');
    });

    test('空对象兜底为可读占位,不抛异常', () {
      expect(normalizeBridgeError(const {}), '未知错误');
      expect(normalizeBridgeError(null), '未知错误');
    });
  });
}
