import 'package:app/models/agent.dart';
import 'package:app/models/conversation.dart';
import 'package:app/models/ws_message.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart' show wsProvider;
import 'package:app/providers/conversation_provider.dart';
import 'package:app/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_local_message_store.dart';
import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;
  late FakeWS ws;

  setUp(() {
    api = MockApi();
    ws = FakeWS();
    // Mock getConversations 返回一条 c1 会话（agent a1 'Bot'）
    when(() => api.getConversations()).thenAnswer((_) async => [
      Conversation(
        id: 'c1',
        type: 'dm_user_agent',
        agent: AgentSummary(
            id: 'a1', name: 'Bot', status: AgentStatus.online),
        participants: [],
        lastMessageContent: {'msg_type': 'text', 'data': {'text': 'old'}},
        lastMessageAt: DateTime.parse('2026-06-13T14:00:00Z'),
        createdAt: DateTime.parse('2026-06-13T10:00:00Z'),
      ),
    ]);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('load 调用 getConversations 并解析', () async {
    final container = makeContainer();

    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();
    final list = container.read(conversationProvider);
    expect(list.length, 1);
    expect(list.first.agent!.name, 'Bot');
    expect(list.first.lastMessagePreview(currentUserId: 'u'), 'old');
  });

  test('onMessageCreate 本地更新预览并置顶', () async {
    final container = makeContainer();

    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();
    expect(container.read(conversationProvider).first.lastMessagePreview(currentUserId: 'u'), 'old');

    // 模拟 WebSocket 推送 MESSAGE_CREATE（c1 的新消息 'new'）
    final wsMsg = WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      s: 1,
      d: {
        'id': 'm1',
        'conversation_id': 'c1',
        'sender_type': 'user',
        'sender_id': 'u1',
        'content': {'msg_type': 'text', 'data': {'text': 'new'}},
        'created_at': '2026-06-13T15:00:00Z',
      },
    );
    ws.emit(wsMsg);
    // 等待 broadcast stream listener 同步处理完消息。
    // broadcast stream + sync listener 实际同步送达，但 delay 提供 microtask 边界保险。
    await Future.delayed(Duration.zero);

    final list = container.read(conversationProvider);
    expect(list.first.lastMessagePreview(currentUserId: 'u'), 'new');
    // lastMessageAt 应取自 payload 的 created_at，而非本地时钟
    expect(list.first.lastMessageAt, DateTime.parse('2026-06-13T15:00:00Z'));
    // c1 本来就是唯一一条，置顶后仍是 c1
    expect(list.first.id, 'c1');
  });

  // ========== silent 守卫 + step_finish 摘要守卫（与 server IncrUnreadTx + bg-service 对齐）==========
  test('silent=true 消息不计未读 + 不更新摘要', () async {
    final container = makeContainer();
    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();

    // 模拟 WebSocket 推送 silent=true 的 step_finish 消息
    final wsMsg = WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      s: 2,
      d: {
        'id': 'm-silent',
        'conversation_id': 'c1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'step_finish',
          'data': {'duration': 1.5},
          'silent': true,
        },
        'created_at': '2026-06-13T16:00:00Z',
      },
    );
    ws.emit(wsMsg);
    await Future.delayed(Duration.zero);

    final conv = container.read(conversationProvider).first;
    // silent=true 不计未读
    expect(conv.unreadCount, 0);
    // step_finish 不更新摘要（保留 'old'）
    expect(conv.lastMessagePreview(currentUserId: 'u'), 'old');
  });

  test('silent=false 消息正常计未读 + 更新摘要', () async {
    final container = makeContainer();
    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();

    final wsMsg = WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      s: 3,
      d: {
        'id': 'm-normal',
        'conversation_id': 'c1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'markdown',
          'data': {'text': 'agent reply'},
        },
        'created_at': '2026-06-13T17:00:00Z',
      },
    );
    ws.emit(wsMsg);
    await Future.delayed(Duration.zero);

    final conv = container.read(conversationProvider).first;
    // 非 active conv → 未读 +1
    expect(conv.unreadCount, 1);
    // 摘要更新为 'agent reply'
    expect(conv.lastMessagePreview(currentUserId: 'u'), 'agent reply');
  });

  test('removeByAgentId 联动移除', () async {
    final container = makeContainer();

    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();
    expect(container.read(conversationProvider).length, 1);

    notifier.removeByAgentId('a1');
    expect(container.read(conversationProvider).length, 0);
  });

  test('onMessageCreate 忽略未知 conversation_id', () async {
    final container = makeContainer();

    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();

    final wsMsg = WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      s: 2,
      d: {
        'id': 'm2',
        'conversation_id': 'unknown-conv-id',
        'sender_type': 'user',
        'sender_id': 'u1',
        'content': {'msg_type': 'text', 'data': {'text': 'unknown'}},
        'created_at': '2026-06-13T15:00:00Z',
      },
    );
    ws.emit(wsMsg);
    // 等待 broadcast stream listener 同步处理完消息。
    // broadcast stream + sync listener 实际同步送达，但 delay 提供 microtask 边界保险。
    await Future.delayed(Duration.zero);

    // 列表不变（c1 仍是 'old'）
    expect(
        container.read(conversationProvider).first.lastMessagePreview(currentUserId: 'u'), 'old');
  });

  test('removeByAgentId 混合列表只删目标 agent', () async {
    // 覆盖 setUp 默认 stub（mocktail 后注册覆盖先注册），返回 2 条不同 agent 的会话
    when(() => api.getConversations()).thenAnswer((_) async => [
          Conversation(
            id: 'c1',
            type: 'dm_user_agent',
            agent: AgentSummary(
                id: 'a1', name: 'AgentA', status: AgentStatus.online),
            participants: [],
            lastMessageContent: {'msg_type': 'text', 'data': {'text': 'A-msg'}},
            lastMessageAt: DateTime.parse('2026-06-13T14:00:00Z'),
            createdAt: DateTime.parse('2026-06-13T10:00:00Z'),
          ),
          Conversation(
            id: 'c2',
            type: 'dm_user_agent',
            agent: AgentSummary(
                id: 'a2', name: 'AgentB', status: AgentStatus.online),
            participants: [],
            lastMessageContent: {'msg_type': 'text', 'data': {'text': 'B-msg'}},
            lastMessageAt: DateTime.parse('2026-06-13T13:00:00Z'),
            createdAt: DateTime.parse('2026-06-13T09:00:00Z'),
          ),
        ]);

    final container = makeContainer();

    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();
    expect(container.read(conversationProvider).length, 2);

    // 删除 a1，c2 应保留
    notifier.removeByAgentId('a1');
    final list = container.read(conversationProvider);
    expect(list.length, 1);
    expect(list.first.id, 'c2');
    expect(list.first.agent!.id, 'a2');
  });

  // ========== pin/unpin/hide + _resort 测试(直接构造 Notifier) ==========
  group('pin/unpin/hide', () {
    late MockApi api2;
    late FakeWS ws2;
    late ConversationListNotifier notifier2;

    Conversation conv(String id, String agentName, DateTime at,
            {bool pinned = false, int unread = 0}) =>
        Conversation(
          id: id,
          type: 'dm_user_agent',
          agent: AgentSummary(
              id: 'a-$id', name: agentName, status: AgentStatus.online),
          participants: [],
          lastMessageContent: null,
          lastMessageAt: at,
          createdAt: DateTime(2026),
          unreadCount: unread,
          pinnedAt: pinned ? DateTime.now() : null,
        );

    setUp(() {
      api2 = MockApi();
      ws2 = FakeWS();
      // autoload=false:本组测 pin/unpin/hide/resort 纯逻辑,构造时不触发 load,
      // 避免对未 stub 的 getConversations 抛 MissingStubError。
      notifier2 = ConversationListNotifier(api2, ws2, 'user-b', FakeLocalMessageStore(), autoload: false);
    });

    test('_resort: 置顶组在前 + 组内按时间倒序', () {
      notifier2.state = [
        conv('c1', 'A', DateTime(2026, 6, 17, 10)),
        conv('c2', 'B', DateTime(2026, 6, 17, 11), pinned: true),
        conv('c3', 'C', DateTime(2026, 6, 17, 9)),
      ];
      notifier2.testResort();
      expect(notifier2.state.map((c) => c.id), ['c2', 'c1', 'c3']);
    });

    test('_resort: 多个置顶按时间倒序', () {
      notifier2.state = [
        conv('c1', 'A', DateTime(2026, 6, 17, 10), pinned: true),
        conv('c2', 'B', DateTime(2026, 6, 17, 11), pinned: true),
      ];
      notifier2.testResort();
      expect(notifier2.state.map((c) => c.id), ['c2', 'c1']);
    });

    test('pin: 调 API + 本地标记 isPinned', () async {
      when(() => api2.pinConversation('c1')).thenAnswer((_) async {});
      notifier2.state = [conv('c1', 'A', DateTime(2026, 6, 17, 10))];
      await notifier2.pin('c1');
      expect(notifier2.state[0].isPinned, isTrue);
      verify(() => api2.pinConversation('c1')).called(1);
    });

    test('pin: API 失败时本地不更新', () async {
      when(() => api2.pinConversation('c1'))
          .thenThrow(Exception('net error'));
      notifier2.state = [conv('c1', 'A', DateTime(2026, 6, 17, 10))];
      try {
        await notifier2.pin('c1');
      } catch (_) {}
      expect(notifier2.state[0].isPinned, isFalse);
    });

    test('unpin: 调 API + 本地标记 isPinned=false', () async {
      when(() => api2.unpinConversation('c1')).thenAnswer((_) async {});
      notifier2.state = [
        conv('c1', 'A', DateTime(2026, 6, 17, 10), pinned: true)
      ];
      await notifier2.unpin('c1');
      expect(notifier2.state[0].isPinned, isFalse);
    });

    test('hide: 调 API + 本地移除', () async {
      when(() => api2.hideConversation('c1')).thenAnswer((_) async {});
      notifier2.state = [
        conv('c1', 'A', DateTime(2026, 6, 17, 10)),
        conv('c2', 'B', DateTime(2026, 6, 17, 11)),
      ];
      await notifier2.hide('c1');
      expect(notifier2.state.length, 1);
      expect(notifier2.state[0].id, 'c2');
    });

    test('hide: API 失败时本地不移除', () async {
      when(() => api2.hideConversation('c1'))
          .thenThrow(Exception('net error'));
      notifier2.state = [conv('c1', 'A', DateTime(2026, 6, 17, 10))];
      try {
        await notifier2.hide('c1');
      } catch (_) {}
      expect(notifier2.state.length, 1);
    });
  });

  // ========== regression: _onMessageCreate / markReadLocally 保留 isPinned ==========
  group('isPinned 保留', () {
    late FakeWS ws3;
    late ConversationListNotifier notifier3;

    setUp(() {
      ws3 = FakeWS();
      // autoload=false:本组测 isPinned 保留逻辑,构造时不触发 load。
      notifier3 = ConversationListNotifier(MockApi(), ws3, 'user-c', FakeLocalMessageStore(), autoload: false);
    });

    test('_onMessageCreate 不能丢 isPinned（regression）', () async {
      notifier3.state = [
        Conversation(
          id: 'c1',
          type: 'dm_user_agent',
          agent: AgentSummary(
              id: 'a1', name: 'Bot', status: AgentStatus.online),
          participants: [],
          lastMessageContent: null,
          lastMessageAt: DateTime(2026, 6, 17, 10),
          createdAt: DateTime(2026),
          pinnedAt: DateTime.now(),
        ),
      ];

      ws3.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': 'm1',
          'conversation_id': 'c1',
          'sender_type': 'user',
          'sender_id': 'u1',
          'content': {'msg_type': 'text', 'data': {'text': 'new'}},
          'created_at': '2026-06-17T11:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier3.state.first.isPinned, isTrue,
          reason: '置顶会话发新消息后 isPinned 必须保留，否则背景色会消失');
      expect(notifier3.state.first.lastMessagePreview(currentUserId: 'u'), 'new');
    });

    test('markReadLocally 不能丢 isPinned（regression）', () async {
      notifier3.state = [
        Conversation(
          id: 'c1',
          type: 'dm_user_agent',
          agent: AgentSummary(
              id: 'a1', name: 'Bot', status: AgentStatus.online),
          participants: [],
          lastMessageContent: null,
          lastMessageAt: DateTime(2026, 6, 17, 10),
          createdAt: DateTime(2026),
          unreadCount: 3,
          pinnedAt: DateTime.now(),
        ),
      ];

      notifier3.markReadLocally('c1');

      expect(notifier3.state.first.isPinned, isTrue,
          reason: '进 ChatPage 清未读时 isPinned 必须保留');
      expect(notifier3.state.first.unreadCount, 0);
    });

    test('_onMessageCreate 排序用 _resort，不能直接 prepend（regression）', () async {
      // 场景：置顶组 + 非置顶组，非置顶的最新消息不应排到置顶组前面
      notifier3.state = [
        Conversation(
          id: 'pinned',
          type: 'dm_user_agent',
          agent: AgentSummary(
              id: 'a-p', name: 'Pinned', status: AgentStatus.online),
          participants: [],
          lastMessageContent: null,
          lastMessageAt: DateTime(2026, 6, 17, 9), // 更早
          createdAt: DateTime(2026),
          pinnedAt: DateTime.now(),
        ),
        Conversation(
          id: 'normal',
          type: 'dm_user_agent',
          agent: AgentSummary(
              id: 'a-n', name: 'Normal', status: AgentStatus.online),
          participants: [],
          lastMessageContent: null,
          lastMessageAt: DateTime(2026, 6, 17, 10),
          createdAt: DateTime(2026),
        ),
      ];

      // normal 收到一条新消息（变最新），但置顶组仍应在前
      ws3.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        s: 1,
        d: {
          'id': 'm1',
          'conversation_id': 'normal',
          'sender_type': 'user',
          'sender_id': 'u1',
          'content': {'msg_type': 'text', 'data': {'text': 'fresh'}},
          'created_at': '2026-06-17T12:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      expect(notifier3.state.map((c) => c.id), ['pinned', 'normal'],
          reason: '非置顶会话即使最新也不应排到置顶组之前');
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

    test('翻转(silent true→false)→ 徽章+1 + 预览更新为最后 markdown 元素', () async {
      final container = makeContainer();
      final notifier = container.read(conversationProvider.notifier);
      await notifier.load();
      expect(container.read(conversationProvider).first.lastMessagePreview(currentUserId: 'u'), 'old');

      // server PATCH 翻转后广播 MESSAGE_UPDATE(content 带 silent:false)
      ws.emitUpdate(flipUpdate(silent: false));
      await Future.delayed(Duration.zero);

      final conv = container.read(conversationProvider).first;
      expect(conv.unreadCount, 1,
          reason: '聚合卡回合结束翻转应计 1 未读(server 已在翻转时 IncrUnread)');
      expect(conv.lastMessagePreview(currentUserId: 'u'), '聚合卡最终回复',
          reason: '预览应取聚合卡最后 markdown 元素的 text');
      expect(conv.id, 'c1');
    });

    test('generating 阶段 MESSAGE_UPDATE(silent 仍 true)→ 不更新徽章/预览', () async {
      final container = makeContainer();
      final notifier = container.read(conversationProvider.notifier);
      await notifier.load();

      ws.emitUpdate(flipUpdate(silent: true, state: 'generating'));
      await Future.delayed(Duration.zero);

      final conv = container.read(conversationProvider).first;
      expect(conv.unreadCount, 0,
          reason: 'generating 阶段 silent 仍 true,不应计未读');
      expect(conv.lastMessagePreview(currentUserId: 'u'), 'old',
          reason: 'generating 阶段不应覆盖会话列表预览');
    });

    test('set_silent 增量 op 翻转 → load() 重拉 server 全量(徽章+1 + 预览更新)', () async {
      final container = makeContainer();
      final notifier = container.read(conversationProvider.notifier);
      await notifier.load();
      expect(container.read(conversationProvider).first.lastMessagePreview(currentUserId: 'u'), 'old');

      // 翻转后 server 列表返回翻转后的聚合卡全量(含 elements + silent:false)
      when(() => api.getConversations()).thenAnswer((_) async => [
        Conversation(
          id: 'c1',
          type: 'dm_user_agent',
          agent: AgentSummary(
              id: 'a1', name: 'Bot', status: AgentStatus.online),
          participants: [],
          lastMessageContent: {
            'msg_type': 'aggregate_card',
            'data': {
              'state': 'done',
              'elements': [
                {'type': 'markdown', 'data': {'text': '聚合卡最终回复'}},
              ],
            },
            'silent': false,
          },
          lastMessageAt: DateTime.parse('2026-06-13T15:00:00Z'),
          createdAt: DateTime.parse('2026-06-13T10:00:00Z'),
          unreadCount: 1,
        ),
      ]);

      // set_silent 增量 delta:silent 在 data 内,顶层无 silent/elements
      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        s: 2,
        d: {
          'message_id': 'm-agg',
          'conversation_id': 'c1',
          'content': {
            'msg_type': 'aggregate_card',
            'data': {'op': 'set_silent', 'silent': false},
          },
        },
      ));
      // 等 _pendingReloadTimer(200ms) + load() 完成
      await Future.delayed(const Duration(milliseconds: 300));

      final conv = container.read(conversationProvider).first;
      expect(conv.unreadCount, 1,
          reason: 'set_silent 增量翻转应计 1 未读(server 已在翻转时 IncrUnread)');
      expect(conv.lastMessagePreview(currentUserId: 'u'), '聚合卡最终回复',
          reason: '预览应经 load() 重拉取 server 全量聚合卡最后 markdown 元素');
      expect(conv.id, 'c1');
    });

    test('set_silent 增量 op silent=true → 不触发 load()', () async {
      final container = makeContainer();
      final notifier = container.read(conversationProvider.notifier);
      await notifier.load();

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
      await Future.delayed(const Duration(milliseconds: 300));

      final conv = container.read(conversationProvider).first;
      expect(conv.unreadCount, 0);
      expect(conv.lastMessagePreview(currentUserId: 'u'), 'old');
    });
  });

  // ========== createGroup: 用 memberUsernames 不用 memberIds ==========
  group('createGroup', () {
    late MockApi api4;
    late FakeWS ws4;
    late ConversationListNotifier notifier4;

    setUp(() {
      api4 = MockApi();
      ws4 = FakeWS();
      // autoload=false:本组测 createGroup 入参,不触发 load。
      notifier4 = ConversationListNotifier(api4, ws4, 'user-d', FakeLocalMessageStore(), autoload: false);
    });

    test('createGroup 传 memberUsernames 不传 memberIds', () async {
      // 用 Invocation 捕获命名参数,后续断言用
      Invocation? captured;
      when(() => api4.createConversation(
            type: any(named: 'type'),
            memberIds: any(named: 'memberIds'),
            memberTypes: any(named: 'memberTypes'),
            memberUsernames: any(named: 'memberUsernames'),
            title: any(named: 'title'),
            avatarUrl: any(named: 'avatarUrl'),
          )).thenAnswer((inv) {
            captured = inv;
            return Future.value(Conversation(
              id: 'g1',
              type: 'group_user',
              title: 'test',
              participants: [],
              lastMessageContent: null,
              // last_message_at 必填(Conversation 构造不接受 null)
              lastMessageAt: DateTime.parse('2026-07-03T00:00:00Z'),
              createdAt: DateTime.parse('2026-07-03T00:00:00Z'),
            ));
          });

      final id = await notifier4.createGroup(
        memberUsernames: const ['alice', 'bob'],
        title: 'test',
      );

      expect(id, 'g1', reason: '应返回新建会话 ID');
      // 关键断言:type=group_user,memberUsernames 透传,memberIds/memberTypes 默认空
      expect(captured!.namedArguments[#type], 'group_user');
      expect(captured!.namedArguments[#memberUsernames], ['alice', 'bob']);
      expect(
          (captured!.namedArguments[#memberIds] as List).isEmpty, isTrue,
          reason: '不应再传 memberIds');
      expect(
          (captured!.namedArguments[#memberTypes] as List).isEmpty, isTrue,
          reason: '不应再传 memberTypes');
      expect(captured!.namedArguments[#title], 'test');
      // 新会话已插入到 state 头部
      expect(notifier4.state.first.id, 'g1');
    });
  });

  test('onMessageDelete 触发 load 刷新列表', () async {
    final container = makeContainer();
    // read 触发构造,autoload 会调一次 getConversations(fire-and-forget)。
    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();
    // 构造 autoload load + 显式 load = 2 次
    verify(() => api.getConversations()).called(2);

    // 模拟 MESSAGE_DELETE(删除事件可能改变 last_message_content)
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_DELETE',
      d: {'ids': ['m1'], 'conversation_id': 'c1'},
    ));
    await Future.delayed(Duration.zero);
    await Future.delayed(Duration.zero); // load 是 async,多等一帧

    // 应触发一次额外 load
    verify(() => api.getConversations()).called(1);
  });

  // ========== F5: cache-first + diff-merge + 落库 ==========
  group('F5: conversationProvider cache-first', () {
    late MockApi api;
    late FakeWS ws;
    late FakeLocalMessageStore store;

    setUp(() {
      api = MockApi();
      ws = FakeWS();
      store = FakeLocalMessageStore();
    });

    test('load 先返 cached, 后台 API 刷新后 diff-merge', () async {
      // arrange: store 有 cached c1,API 返 fresh c2(新)
      final cachedConv = Conversation(
        id: 'c1',
        type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 1),
        createdAt: DateTime.utc(2026, 7, 1),
        unreadCount: 0,
      );
      await store.putConversations('u1', [cachedConv]);

      final freshConv = Conversation(
        id: 'c2',
        type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 2),
        unreadCount: 0,
      );
      when(() => api.getConversations()).thenAnswer((_) async => [freshConv]);

      final notifier = ConversationListNotifier(api, ws, 'u1', store);

      // 等一拍让 load() 完成(cache-first + API 刷新)
      await Future.delayed(const Duration(milliseconds: 50));

      final state = notifier.state;
      // c1 被 fresh 删除, c2 新增
      expect(state.where((c) => c.id == 'c1'), isEmpty);
      expect(state.where((c) => c.id == 'c2').length, 1);
      // store 被覆盖写入 fresh
      final stored = await store.getConversations('u1');
      expect(stored.where((c) => c.id == 'c2').length, 1);
    });

    test('unreadCount active 强制 0', () async {
      final conv = Conversation(
        id: 'c1',
        type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
        unreadCount: 5,
      );
      when(() => api.getConversations()).thenAnswer((_) async => [conv]);

      final notifier = ConversationListNotifier(api, ws, 'u1', store);
      notifier.setActiveConv('c1');

      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.state.first.unreadCount, 0); // active 强制 0
    });

    test('unreadCount 跨设备同步:用 fresh 真值(覆盖本地缓存)', () async {
      // 场景:A 设备已读部分消息,server unread=3;B 设备本地缓存还是 10(旧的)
      // 期望:B 设备下拉刷新后 unread=3(server 真值),不再用 max 保留旧的 10
      final cached = Conversation(
        id: 'c1',
        type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
        unreadCount: 10,
      );
      await store.putConversations('u1', [cached]);

      final fresh = Conversation(
        id: 'c1',
        type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
        unreadCount: 3,
      );
      when(() => api.getConversations()).thenAnswer((_) async => [fresh]);

      final notifier = ConversationListNotifier(api, ws, 'u1', store);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.state.first.unreadCount, 3); // server 真值生效
    });

    test('API 返空但 local 非空 → 不覆盖', () async {
      final cached = Conversation(
        id: 'c1',
        type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
      );
      await store.putConversations('u1', [cached]);
      when(() => api.getConversations()).thenAnswer((_) async => []);

      final notifier = ConversationListNotifier(api, ws, 'u1', store);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.state.length, 1); // 本地保留
      expect(notifier.state.first.id, 'c1');
    });

    test('WS MESSAGE_CREATE 落库 store.putConversation', () async {
      final conv = Conversation(
        id: 'c1',
        type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 1),
        createdAt: DateTime.utc(2026, 7, 1),
      );
      when(() => api.getConversations()).thenAnswer((_) async => [conv]);

      // 构造即触发 autoload load。notifier 不需要被引用(测试只检查 store 内容),
      // 但赋值给 _ 显式标注,避免 unused warning。
      final _ = ConversationListNotifier(api, ws, 'u1', store);
      await Future.delayed(const Duration(milliseconds: 50));

      // 触发 WS MESSAGE_CREATE
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        d: {
          'id': 'm1',
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'a1',
          'content': {'msg_type': 'text', 'data': {'text': 'hi'}},
          'created_at': DateTime.utc(2026, 7, 5).toIso8601String(),
        },
      ));

      await Future.delayed(const Duration(milliseconds: 50));

      // store 中 c1 被刷新(putConversation 单条 upsert)
      final stored = await store.getConversations('u1');
      expect(stored.where((c) => c.id == 'c1').length, 1);
      expect(
        stored.firstWhere((c) => c.id == 'c1').lastMessageContent?['msg_type'],
        'text',
      );
    });

    // 回归测试:leaveConversation 后立即下拉刷新,旧 cached(可能因
    // _persistList fire-and-forget 滞后写入)不应覆盖已更新的 state。
    // 否则 UI 会闪现已退群/已隐藏的会话(真实场景:用户报告下拉刷新闪现)。
    test('state 非空时 load 不应被旧 cached 覆盖(防闪现)', () async {
      Conversation conv(String id) => Conversation(
            id: id,
            type: 'dm_user_agent',
            participants: const [],
            lastMessageContent: null,
            lastMessageAt: DateTime.utc(2026, 7, 1),
            createdAt: DateTime.utc(2026, 7, 1),
          );

      // 初始 cached=[A,B,C],fresh 也=[A,B,C],首次 load 后 state=[A,B,C]
      final initial = [conv('A'), conv('B'), conv('C')];
      await store.putConversations('u1', initial);
      when(() => api.getConversations()).thenAnswer((_) async => initial);

      final notifier = ConversationListNotifier(api, ws, 'u1', store);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.state.length, 3);

      // leaveConversation('C') → state=[A,B]
      when(() => api.leaveConversation('C')).thenAnswer((_) async {});
      await notifier.leaveConversation('C');
      expect(notifier.state.where((c) => c.id == 'C'), isEmpty);
      expect(notifier.state.length, 2);

      // 模拟 _persistList 滞后未写入:store 仍是 [A,B,C]
      // (实际场景是 fire-and-forget 异步未完成,这里手动重置模拟)
      await store.putConversations('u1', initial);

      // 用户下拉刷新:server 已知 C 退出,fresh=[A,B]
      when(() => api.getConversations())
          .thenAnswer((_) async => [conv('A'), conv('B')]);
      await notifier.load();
      await Future.delayed(const Duration(milliseconds: 50));

      // 关键断言:C 不应闪现(说明 cached 没覆盖 state)
      expect(notifier.state.where((c) => c.id == 'C'), isEmpty,
          reason: 'state 已是 [A,B],旧 cached=[A,B,C] 不应覆盖,否则 UI 闪现 C');
      expect(notifier.state.length, 2);
    });

    // 多端同步:A 设备 markRead 后 server 广播 MESSAGE_READ,
    // B 设备 conversationProvider 监听后立即刷本地 unreadCount(不等下拉刷新)。
    test('MESSAGE_READ 多端同步:立即刷本地 unreadCount', () async {
      // 初始 cached=[A(unread=5)],fresh 同
      final cached = Conversation(
        id: 'A',
        type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
        unreadCount: 5,
      );
      await store.putConversations('u1', [cached]);
      when(() => api.getConversations()).thenAnswer((_) async => [cached]);

      final notifier = ConversationListNotifier(api, ws, 'u1', store);
      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.state.first.unreadCount, 5);

      // 模拟 A 设备已读 → server 广播 MESSAGE_READ
      ws.emitMessageRead(WSMessage(
        op: 0,
        t: 'MESSAGE_READ',
        d: {
          'conversation_id': 'A',
          'message_ids': ['m1', 'm2'],
          'unread_count': 0,
          'read_at': DateTime.utc(2026, 7, 6).toIso8601String(),
        },
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.state.first.unreadCount, 0,
          reason: '收到 MESSAGE_READ 后应立即同步徽章为 0');
    });

    test('cache-first 过滤 agent_session(对齐 server ListForUser,防列表污染)', () async {
      // 模拟 chat_provider._initialize 写回的 agent_session 缓存
      await store.putConversation('u1', Conversation(
        id: 'cAS', type: 'agent_session',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 6),
        createdAt: DateTime.utc(2026, 7, 6),
      ));
      // 正常会话
      await store.putConversation('u1', Conversation(
        id: 'cDM', type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 6),
        createdAt: DateTime.utc(2026, 7, 6),
      ));

      final notifier = ConversationListNotifier(
        api, ws, 'u1', store, autoload: false,
      );
      await notifier.load();

      expect(notifier.state.length, 1, reason: 'agent_session 应被过滤,只剩 dm_user_agent');
      expect(notifier.state.first.id, 'cDM');
    });
  });

  // ========== T5: MESSAGE_UPDATE 审批卡终态 → load() 刷新 pendingCount ==========
  group('MESSAGE_UPDATE pendingCount', () {
    Conversation dmEntry() => Conversation(
          id: 'dm-1',
          type: 'dm_user_agent',
          agent: AgentSummary(
              id: 'agent-1', name: 'Bot', status: AgentStatus.online),
          participants: const [],
          lastMessageContent: null,
          lastMessageAt: DateTime(2026, 7, 1),
          createdAt: DateTime(2026, 7, 1),
        );

    test('permission_card 终态 → 触发 load()', () async {
      var loadCount = 0;
      when(() => api.getConversations()).thenAnswer((_) async {
        loadCount++;
        return [dmEntry()];
      });

      final notifier =
          ConversationListNotifier(api, ws, 'user-1', FakeLocalMessageStore());
      await notifier.load();
      final initialLoadCount = loadCount;

      // MESSAGE_UPDATE 必须用 emitUpdate 推 messageUpdates 独立流
      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        s: 1,
        d: {
          'message_id': 'm-perm',
          'conversation_id': 'session-conv-1',
          'content': {
            'msg_type': 'permission_card',
            'data': {'status': 'approved'},
          },
        },
      ));
      // debounce: _onMessageUpdate 用 Timer 200ms 合并多次 load(),
      // 等够 250ms(200ms Timer + 余量)让 fire-and-forget 触发。
      await Future.delayed(const Duration(milliseconds: 250));

      expect(loadCount, greaterThan(initialLoadCount),
          reason: 'permission_card 终态变更应触发 load() 刷新 pendingCount');
    });

    test('非卡片 MESSAGE_UPDATE → 不触发 load()', () async {
      var loadCount = 0;
      when(() => api.getConversations()).thenAnswer((_) async {
        loadCount++;
        return [dmEntry()];
      });

      final notifier =
          ConversationListNotifier(api, ws, 'user-1', FakeLocalMessageStore());
      await notifier.load();
      final initialLoadCount = loadCount;

      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        s: 1,
        d: {
          'message_id': 'm-text',
          'conversation_id': 'session-conv-1',
          'content': {
            'msg_type': 'text',
            'data': {'text': 'edited'},
          },
        },
      ));
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(loadCount, initialLoadCount,
          reason: '非卡片消息编辑不应触发 load()');
    });
  });
}
