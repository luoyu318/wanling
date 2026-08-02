import 'package:app/models/agent.dart';
import 'package:app/models/conversation.dart';
import 'package:app/models/ws_message.dart';
import 'package:app/providers/agent_sessions_provider.dart';
import 'package:app/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

/// 构造一个 agent_session 会话(c1, unreadCount=0)。
Conversation _session({int unread = 0}) => Conversation(
      id: 'c1',
      type: 'agent_session',
      agent: AgentSummary(
          id: 'agent-1', name: 'Wanling', status: AgentStatus.online),
      participants: const [],
      lastMessageContent: const {'msg_type': 'text', 'data': {'text': 'old'}},
      lastMessageAt: DateTime.utc(2026, 7, 1, 10),
      createdAt: DateTime.utc(2026, 7, 1),
      unreadCount: unread,
    );

/// 构造一条 agent 发送的 MESSAGE_CREATE。
/// [silent] 控制 content.silent 字段(过程类消息为 true)。
WSMessage _agentMessage({
  required String id,
  required bool silent,
  String msgType = 'step_finish',
}) {
  return WSMessage(
    op: 0,
    t: 'MESSAGE_CREATE',
    s: 1,
    d: {
      'id': id,
      'conversation_id': 'c1',
      'sender_type': 'agent',
      'sender_id': 'agent-1',
      'content': {
        'msg_type': msgType,
        'data': {'duration': 1.5},
        if (silent) 'silent': true,
      },
      'created_at': '2026-07-01T11:00:00Z',
    },
  );
}

void main() {
  late MockApi api;
  late FakeWS ws;

  setUp(() {
    api = MockApi();
    ws = FakeWS();
    // load() 默认返回一条 c1 会话(unreadCount=0)
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [_session()]);
  });

  // 构造 notifier + 等 load() 完成(state 非 null)。
  // 构造函数已 fire-and-forget 调一次 load,这里显式 await 确保 state 就绪。
  Future<AgentSessionsNotifier> boot() async {
    final notifier = AgentSessionsNotifier(api, ws, 'user-1', 'agent-1');
    await notifier.load();
    return notifier;
  }

  // ========== silent 守卫(对齐 server IncrUnreadTx + bg-service +
  // conversationProvider + chatStateListener 四路口径)==========
  group('silent 守卫', () {
    test('silent=true 的 agent 消息不计未读', () async {
      final notifier = await boot();
      // 兜底断言:初始 unread=0
      expect(notifier.state!.first.unreadCount, 0);

      ws.emit(_agentMessage(id: 'm-silent', silent: true));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.unreadCount, 0,
          reason: 'silent=true 表示过程类消息,server 已跳过 IncrUnreadTx,'
              'APP 端也必须跳过,否则徽章与 server unread_count 不一致');
    });

    test('silent=false(缺省)的 agent 消息正常计未读', () async {
      final notifier = await boot();
      expect(notifier.state!.first.unreadCount, 0);

      ws.emit(_agentMessage(id: 'm-normal', silent: false));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.unreadCount, 1,
          reason: '非 silent 的 agent 消息应 +1 未读');
    });
  });

  // ========== 基础回归:WS 实时更新 last_message + 置顶排序 ==========
  group('基础行为', () {
    test('MESSAGE_CREATE 更新 lastMessageContent + lastMessageAt', () async {
      final notifier = await boot();

      ws.emit(_agentMessage(id: 'm-update', silent: false, msgType: 'markdown'));
      await Future.delayed(Duration.zero);

      final conv = notifier.state!.first;
      expect(conv.id, 'c1');
      expect(conv.lastMessageContent!['msg_type'], 'markdown');
      expect(conv.lastMessageAt, DateTime.parse('2026-07-01T11:00:00Z'));
    });

    test('markReadLocally 清未读', () async {
      final notifier = await boot();
      // 先制造一条未读
      ws.emit(_agentMessage(id: 'm-read', silent: false));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.unreadCount, 1);

      notifier.markReadLocally('c1');
      expect(notifier.state!.first.unreadCount, 0);
    });
  });

  // ========== createSession:user 主动建 agent_session 群 ==========
  group('createSession', () {
    test('成功 → 调 createConversation + load + 返回新 convId', () async {
      final notifier = await boot();

      final newConv = Conversation(
        id: 'c-new',
        type: 'agent_session',
        agent: AgentSummary(
            id: 'agent-1', name: 'Wanling', status: AgentStatus.online),
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 17, 12),
        createdAt: DateTime.utc(2026, 7, 17),
        unreadCount: 0,
      );

      when(() => api.createConversation(
            type: 'agent_session',
            memberIds: ['agent-1'],
            memberTypes: const ['agent'],
            title: null,
          )).thenAnswer((_) async => newConv);
      // load() 第二次调用返新列表(含新群)
      when(() => api.getAgentSessions('agent-1'))
          .thenAnswer((_) async => [_session(), newConv]);

      final convId = await notifier.createSession('agent-1');

      expect(convId, 'c-new');
      verify(() => api.createConversation(
            type: 'agent_session',
            memberIds: ['agent-1'],
            memberTypes: const ['agent'],
            title: null,
          )).called(1);
      // state 含新群
      expect(notifier.state!.any((c) => c.id == 'c-new'), isTrue);
    });

    test('createConversation 失败 → 抛异常,state 不变', () async {
      final notifier = await boot();
      final originalLen = notifier.state!.length;

      when(() => api.createConversation(
            type: 'agent_session',
            memberIds: any(named: 'memberIds'),
            memberTypes: any(named: 'memberTypes'),
          )).thenThrow(Exception('network'));

      expect(
        () => notifier.createSession('agent-1'),
        throwsA(isA<Exception>()),
      );
      // 等微任务
      await Future.delayed(Duration.zero);

      expect(notifier.state!.length, originalLen, reason: '失败不应改 state');
    });
  });

  // ========== createSession:directory 透传(无本地 stash,直传 server)==========
  group('createSession directory', () {
    Conversation newConvWithId(String id) => Conversation(
          id: id,
          type: 'agent_session',
          agent: AgentSummary(
              id: 'agent-1', name: 'Wanling', status: AgentStatus.online),
          participants: const [],
          lastMessageContent: null,
          lastMessageAt: DateTime.utc(2026, 7, 17, 12),
          createdAt: DateTime.utc(2026, 7, 17),
          unreadCount: 0,
        );

    test('directory 透传给 createConversation API(server 写 conversations.directory)',
        () async {
      final notifier = await boot();
      when(() => api.createConversation(
            type: 'agent_session',
            memberIds: ['agent-1'],
            memberTypes: const ['agent'],
            title: null,
            directory: '/home/user/proj',
          )).thenAnswer((_) async => newConvWithId('c-dir'));

      final convId =
          await notifier.createSession('agent-1', directory: '/home/user/proj');

      expect(convId, 'c-dir');
      verify(() => api.createConversation(
            type: 'agent_session',
            memberIds: ['agent-1'],
            memberTypes: const ['agent'],
            title: null,
            directory: '/home/user/proj',
          )).called(1);
    });
  });

  // ========== pendingCount 增量(审批卡片状态联动)==========
  group('pendingCount 增量', () {
    test('MESSAGE_CREATE pending permission_card → pendingCount +1', () async {
      when(() => api.getAgentSessions('agent-1')).thenAnswer(
        (_) async => [_session()],
      );
      final notifier = await boot();
      expect(notifier.state!.first.pendingCount, 0);

      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': 'm-perm',
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'agent-1',
          'content': {
            'msg_type': 'permission_card',
            'data': {'status': 'pending', 'action': 'bash'},
            'silent': true,
          },
          'created_at': '2026-07-01T11:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.pendingCount, 1);
    });

    test('MESSAGE_CREATE pending question_card → pendingCount +1', () async {
      final notifier = await boot();

      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': 'm-qa',
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'agent-1',
          'content': {
            'msg_type': 'question_card',
            'data': {'status': 'pending'},
            'silent': true,
          },
          'created_at': '2026-07-01T11:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.pendingCount, 1);
    });

    test('MESSAGE_CREATE 非卡片类型 → pendingCount 不变', () async {
      final notifier = await boot();

      ws.emit(_agentMessage(id: 'm-text', silent: false, msgType: 'text'));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.pendingCount, 0);
    });

    test('MESSAGE_UPDATE 终态 → pendingCount -1', () async {
      final notifier = await boot();

      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': 'm-perm',
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'agent-1',
          'content': {
            'msg_type': 'permission_card',
            'data': {'status': 'pending'},
            'silent': true,
          },
          'created_at': '2026-07-01T11:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.pendingCount, 1);

      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        s: 2,
        d: {
          'message_id': 'm-perm',
          'conversation_id': 'c1',
          'content': {
            'msg_type': 'permission_card',
            'data': {'status': 'approved'},
          },
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.pendingCount, 0);
    });

    test('MESSAGE_UPDATE 非卡片类型 → pendingCount 不变', () async {
      final notifier = await boot();
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': 'm-perm',
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'agent-1',
          'content': {
            'msg_type': 'permission_card',
            'data': {'status': 'pending'},
            'silent': true,
          },
          'created_at': '2026-07-01T11:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.pendingCount, 1);

      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        s: 2,
        d: {
          'message_id': 'm-text',
          'conversation_id': 'c1',
          'content': {
            'msg_type': 'text',
            'data': {'text': 'edited'},
          },
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.pendingCount, 1);
    });

    test('pendingCount 不会降到负数', () async {
      final notifier = await boot();

      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        s: 1,
        d: {
          'message_id': 'm-ghost',
          'conversation_id': 'c1',
          'content': {
            'msg_type': 'permission_card',
            'data': {'status': 'approved'},
          },
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.pendingCount, 0);
    });
  });

  // ========== lastUserMessageContent 实时派生 ==========
  // 二级列表摘要只显示「用户最后一条文字消息」(与 server
  // ListAgentSessionsForUser SQL 的 msg_type IN ('text','tui_user') 规则对齐)。
  // WS MESSAGE_CREATE 实时派生避免下拉刷新才看到最新摘要。
  group('lastUserMessageContent 实时派生', () {
    WSMessage _userMessage({
      required String id,
      required String msgType,
      required String text,
    }) {
      return WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': id,
          'conversation_id': 'c1',
          'sender_type': 'user',
          'sender_id': 'user-1',
          'content': {
            'msg_type': msgType,
            'data': {'text': text},
          },
          'created_at': '2026-07-01T11:30:00Z',
        },
      );
    }

    test('user 发 text → lastUserMessageContent 实时更新为文本', () async {
      final notifier = await boot();
      // 初始为空(server SQL 未返回 last_user_message_content 时为 null)
      expect(notifier.state!.first.lastUserMessageContent, isNull);

      ws.emit(_userMessage(id: 'm-u1', msgType: 'text', text: '帮我改bug'));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.lastUserMessageContent, '帮我改bug');
    });

    test('user 发 tui_user → lastUserMessageContent 带 [TUI] 前缀', () async {
      final notifier = await boot();

      ws.emit(_userMessage(id: 'm-u2', msgType: 'tui_user', text: '终端里敲的'));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.lastUserMessageContent, '[TUI] 终端里敲的');
    });

    test('text 后发 tui_user → 取最新 tui_user(覆盖旧 text)', () async {
      final notifier = await boot();

      ws.emit(_userMessage(id: 'm-u3', msgType: 'text', text: '旧指令'));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.lastUserMessageContent, '旧指令');

      ws.emit(_userMessage(id: 'm-u4', msgType: 'tui_user', text: '新指令'));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.lastUserMessageContent, '[TUI] 新指令');
    });

    test('user 发 image → lastUserMessageContent 不变(非文字类型不参与)', () async {
      final notifier = await boot();
      // 先发一条 text 设定基线
      ws.emit(_userMessage(id: 'm-u5', msgType: 'text', text: '基线'));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.lastUserMessageContent, '基线');

      // 再发 image,不应覆盖
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': 'm-u6',
          'conversation_id': 'c1',
          'sender_type': 'user',
          'sender_id': 'user-1',
          'content': {
            'msg_type': 'image',
            'data': {'url': 'x.png'},
          },
          'created_at': '2026-07-01T11:31:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.lastUserMessageContent, '基线');
    });

    test('agent 发消息 → lastUserMessageContent 不变(只跟踪 user 自己)', () async {
      final notifier = await boot();
      // 先 user 发一条 text
      ws.emit(_userMessage(id: 'm-u7', msgType: 'text', text: '我的问题'));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.lastUserMessageContent, '我的问题');

      // agent 回复,不应覆盖 lastUserMessageContent
      ws.emit(_agentMessage(id: 'm-a1', silent: false, msgType: 'text'));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.lastUserMessageContent, '我的问题');
    });

    test('plugin 代发 tui_user(sender=agent) → lastUserMessageContent 仍带 [TUI] 前缀', () async {
      final notifier = await boot();
      // plugin 用 agent JWT 连 WS,落库 sender_type=agent/sender_id=agent-1。
      // 与 chat page 的 effectiveIsMe = isMe || isTuiUser 同构,摘要层也应归位为用户消息。
      // 生产三路(proxy/engine/ensure)恒发 silent:true,测试对齐生产避免与真实数据不符。
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': 'm-tui-agent',
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'agent-1',
          'content': {
            'msg_type': 'tui_user',
            'data': {'text': '终端代发的'},
            'silent': true,
          },
          'created_at': '2026-07-01T11:36:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.lastUserMessageContent, '[TUI] 终端代发的');
      // tui_user 是用户自己终端发的,silent 保证不计未读(避免自己给自己加未读)
      expect(notifier.state!.first.unreadCount, 0);
    });
  });
}
