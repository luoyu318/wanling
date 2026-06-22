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
      {
        'id': 'c1',
        'agent': {
          'id': 'a1',
          'name': 'Bot',
          'avatar_url': null,
          'owner_id': 'u1',
          'status': 'online',
          'created_at': '2026-06-13T00:00:00Z',
        },
        'last_message_content': {'msg_type': 'text', 'data': {'text': 'old'}},
        'last_message_at': '2026-06-13T14:00:00Z',
        'created_at': '2026-06-13T10:00:00Z',
      },
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
    expect(list.first.agent.name, 'Bot');
    expect(list.first.lastMessagePreview, 'old');
  });

  test('onMessageCreate 本地更新预览并置顶', () async {
    final container = makeContainer();

    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();
    expect(container.read(conversationProvider).first.lastMessagePreview, 'old');

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
    expect(list.first.lastMessagePreview, 'new');
    // lastMessageAt 应取自 payload 的 created_at，而非本地时钟
    expect(list.first.lastMessageAt, DateTime.parse('2026-06-13T15:00:00Z'));
    // c1 本来就是唯一一条，置顶后仍是 c1
    expect(list.first.id, 'c1');
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
        container.read(conversationProvider).first.lastMessagePreview, 'old');
  });

  test('removeByAgentId 混合列表只删目标 agent', () async {
    // 覆盖 setUp 默认 stub（mocktail 后注册覆盖先注册），返回 2 条不同 agent 的会话
    when(() => api.getConversations()).thenAnswer((_) async => [
          {
            'id': 'c1',
            'agent': {
              'id': 'a1',
              'name': 'AgentA',
              'avatar_url': null,
              'owner_id': 'u1',
              'status': 'online',
              'created_at': '2026-06-13T00:00:00Z',
            },
            'last_message_content': {'msg_type': 'text', 'data': {'text': 'A-msg'}},
            'last_message_at': '2026-06-13T14:00:00Z',
            'created_at': '2026-06-13T10:00:00Z',
          },
          {
            'id': 'c2',
            'agent': {
              'id': 'a2',
              'name': 'AgentB',
              'avatar_url': null,
              'owner_id': 'u1',
              'status': 'online',
              'created_at': '2026-06-13T00:00:00Z',
            },
            'last_message_content': {'msg_type': 'text', 'data': {'text': 'B-msg'}},
            'last_message_at': '2026-06-13T13:00:00Z',
            'created_at': '2026-06-13T09:00:00Z',
          },
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
    expect(list.first.agent.id, 'a2');
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
          agent: Agent(
              id: 'a-$id', name: agentName, status: AgentStatus.online),
          lastMessageContent: null,
          lastMessageAt: at,
          createdAt: DateTime(2026),
          unreadCount: unread,
          isPinned: pinned,
        );

    setUp(() {
      api2 = MockApi();
      ws2 = FakeWS();
      notifier2 = ConversationListNotifier(api2, ws2);
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
      notifier3 = ConversationListNotifier(MockApi(), ws3);
    });

    test('_onMessageCreate 不能丢 isPinned（regression）', () async {
      notifier3.state = [
        Conversation(
          id: 'c1',
          agent: Agent(
              id: 'a1', name: 'Bot', status: AgentStatus.online),
          lastMessageContent: null,
          lastMessageAt: DateTime(2026, 6, 17, 10),
          createdAt: DateTime(2026),
          isPinned: true,
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
      expect(notifier3.state.first.lastMessagePreview, 'new');
    });

    test('markReadLocally 不能丢 isPinned（regression）', () async {
      notifier3.state = [
        Conversation(
          id: 'c1',
          agent: Agent(
              id: 'a1', name: 'Bot', status: AgentStatus.online),
          lastMessageContent: null,
          lastMessageAt: DateTime(2026, 6, 17, 10),
          createdAt: DateTime(2026),
          unreadCount: 3,
          isPinned: true,
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
          agent: Agent(
              id: 'a-p', name: 'Pinned', status: AgentStatus.online),
          lastMessageContent: null,
          lastMessageAt: DateTime(2026, 6, 17, 9), // 更早
          createdAt: DateTime(2026),
          isPinned: true,
        ),
        Conversation(
          id: 'normal',
          agent: Agent(
              id: 'a-n', name: 'Normal', status: AgentStatus.online),
          lastMessageContent: null,
          lastMessageAt: DateTime(2026, 6, 17, 10),
          createdAt: DateTime(2026),
          isPinned: false,
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

  test('onMessageDelete 触发 load 刷新列表', () async {
    final container = makeContainer();
    final notifier = container.read(conversationProvider.notifier);
    await notifier.load();
    // load 被调用 1 次(setUp 的 when)
    verify(() => api.getConversations()).called(1);

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
}
