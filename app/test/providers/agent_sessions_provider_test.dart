import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart';
import 'package:wanling_core/services/api_service.dart';
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

  // ========== C2: 聚合卡 MESSAGE_UPDATE silent 翻转 → 徽章+1 + 预览更新 ==========
  group('MESSAGE_UPDATE 聚合卡翻转', () {
    WSMessage flipUpdate({required bool silent, String state = 'done'}) =>
        WSMessage(
          op: 0,
          t: 'MESSAGE_UPDATE',
          s: 2,
          d: {
            'message_id': 'm-agg',
            'conversation_id': 'c1',
            'content': {
              'msg_type': 'aggregate_card',
              'data': {
                'state': state,
                'elements': [
                  {'type': 'markdown', 'data': {'text': '聚合卡最终回复'}},
                ],
              },
              'silent': silent,
            },
          },
        );

    test('翻转(silent true→false)→ 徽章+1 + lastMessageContent 更新为最后 markdown 元素',
        () async {
      final notifier = await boot();

      // server PATCH 翻转后广播 MESSAGE_UPDATE(content 带 silent:false)
      ws.emitUpdate(flipUpdate(silent: false));
      await Future.delayed(Duration.zero);

      final conv = notifier.state!.first;
      expect(conv.unreadCount, 1,
          reason: '聚合卡回合结束翻转应计 1 未读(server 已在翻转时 IncrUnread)');
      expect(conv.lastMessageContent!['msg_type'], 'aggregate_card');
      expect(conv.lastMessagePreview(currentUserId: 'user-1'), '聚合卡最终回复',
          reason: '预览应取聚合卡最后 markdown 元素的 text');
      expect(conv.lastAgentReplyContent, '聚合卡最终回复',
          reason: '聚合卡翻转也算 agent 回复摘要(对齐 server SQL data.preview 口径)');
    });

    test('generating 阶段 MESSAGE_UPDATE(silent 仍 true)→ 不更新徽章/预览', () async {
      final notifier = await boot();

      ws.emitUpdate(flipUpdate(silent: true, state: 'generating'));
      await Future.delayed(Duration.zero);

      final conv = notifier.state!.first;
      expect(conv.unreadCount, 0,
          reason: 'generating 阶段 silent 仍 true,不应计未读');
      expect(conv.lastMessagePreview(currentUserId: 'user-1'), 'old',
          reason: 'generating 阶段不应覆盖会话列表预览');
    });

    test('set_silent 增量 op 翻转 → 本地更新(徽章+1 + preview 摘要,不走 load)',
        () async {
      final notifier = await boot();
      // 清掉 boot() 期间的 load 调用记录,翻转后断言不再触发 load():
      // set_silent 翻转本地即可更新(广播 delta 带 preview),走 load() 会与
      // MESSAGE_READ 竞态覆盖已清零的 state(列表徽章残留)。
      clearInteractions(api);

      // set_silent 增量 delta:silent 在 data 内,带 server 翻转写入的 preview
      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        s: 2,
        d: {
          'message_id': 'm-agg',
          'conversation_id': 'c1',
          'content': {
            'msg_type': 'aggregate_card',
            'data': {
              'op': 'set_silent',
              'silent': false,
              'preview': '聚合卡最终回复',
            },
          },
        },
      ));
      await Future.delayed(Duration.zero);

      final conv = notifier.state!.first;
      expect(conv.unreadCount, 1,
          reason: 'set_silent 增量翻转应计 1 未读(server 已在翻转时 IncrUnread)');
      expect(conv.lastMessagePreview(currentUserId: 'user-1'), '聚合卡最终回复',
          reason: '预览应取广播 delta 的 data.preview');
      expect(conv.lastAgentReplyContent, '聚合卡最终回复',
          reason: '聚合卡翻转摘要从 preview 本地派生');
      // load() 不应被翻转触发(避免与 MESSAGE_READ 竞态覆盖本地已清零 state)
      verifyNever(() => api.getAgentSessions(any()));
    });

    test('set_silent 增量 op silent=true → 不触发 load()', () async {
      final notifier = await boot();

      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        s: 2,
        d: {
          'message_id': 'm-agg',
          'conversation_id': 'c1',
          'content': {
            'msg_type': 'aggregate_card',
            'data': {'op': 'set_silent', 'silent': true},
          },
        },
      ));
      await Future.delayed(const Duration(milliseconds: 100));

      final conv = notifier.state!.first;
      expect(conv.unreadCount, 0);
      expect(conv.lastMessagePreview(currentUserId: 'user-1'), 'old');
    });
  });

  // ========== lastAgentReplyContent 实时派生 ==========
  // 二级列表摘要显示「agent 最后一条最终回复」(与 server
  // ListAgentSessionsForUser SQL 的 msg_type IN ('text','markdown')
  // AND silent IS DISTINCT FROM 'true' 规则对齐)。
  // WS MESSAGE_CREATE 实时派生避免下拉刷新才看到最新摘要。
  group('lastAgentReplyContent 实时派生', () {
    WSMessage agentReply({
      required String id,
      required String msgType,
      required String text,
      bool silent = false,
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
            'data': {'text': text},
            if (silent) 'silent': true,
          },
          'created_at': '2026-07-01T11:30:00Z',
        },
      );
    }

    test('agent 发非 silent markdown → lastAgentReplyContent 实时更新为文本', () async {
      final notifier = await boot();
      // 初始为空(server SQL 未返回 last_agent_reply_content 时为 null)
      expect(notifier.state!.first.lastAgentReplyContent, isNull);

      ws.emit(agentReply(id: 'm-a1', msgType: 'markdown', text: '已经改好了'));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.lastAgentReplyContent, '已经改好了');
    });

    test('agent 发非 silent text → lastAgentReplyContent 也更新', () async {
      final notifier = await boot();

      ws.emit(agentReply(id: 'm-a2', msgType: 'text', text: '文字回复'));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.lastAgentReplyContent, '文字回复');
    });

    test('agent 发 silent 过程消息 → lastAgentReplyContent 不变', () async {
      final notifier = await boot();
      // 先一条最终回复设基线
      ws.emit(agentReply(id: 'm-a3', msgType: 'markdown', text: '基线回复'));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.lastAgentReplyContent, '基线回复');

      // silent 过程消息(中间步骤 markdown / reasoning / step_finish)不应覆盖
      ws.emit(agentReply(
          id: 'm-a4', msgType: 'markdown', text: '中间步骤', silent: true));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.lastAgentReplyContent, '基线回复');

      ws.emit(agentReply(
          id: 'm-a5', msgType: 'reasoning', text: '思考中', silent: true));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.lastAgentReplyContent, '基线回复');
    });

    test('user 发消息 → lastAgentReplyContent 不变(只跟踪 agent 回复)', () async {
      final notifier = await boot();
      // 先 agent 发一条回复
      ws.emit(agentReply(id: 'm-a6', msgType: 'markdown', text: '我的答复'));
      await Future.delayed(Duration.zero);
      expect(notifier.state!.first.lastAgentReplyContent, '我的答复');

      // user 新指令,不应覆盖 lastAgentReplyContent
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': 'm-u1',
          'conversation_id': 'c1',
          'sender_type': 'user',
          'sender_id': 'user-1',
          'content': {
            'msg_type': 'text',
            'data': {'text': '新问题'},
          },
          'created_at': '2026-07-01T11:31:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier.state!.first.lastAgentReplyContent, '我的答复');
    });
  });
}
