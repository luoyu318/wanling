import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/quote.dart';
import 'package:wanling_core/models/unread_info.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/chat_state.dart' show ModelOverride;
import 'package:wanling_core/rendering/card_renderer.dart';
import 'package:wanling_core/services/api_service.dart';
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
    // _initialize 现在调 getUnreadInfo + getMessagesBefore（无未读路径）。
    // 兜底 catch 分支仍可能调 getMessages，保留 mock。
    when(() => api.getUnreadInfo(any()))
        .thenAnswer((_) async => const UnreadInfo(unreadCount: 0));
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => <ChatMessage>[]);
    when(() => api.getMessages(any(),
            limit: any(named: 'limit'), offset: any(named: 'offset')))
        .thenAnswer((_) async => <ChatMessage>[]);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);
    // chatProvider 是 autoDispose.family：没有 listener 时容器会在帧间隙回收
    // provider 实例。测试用例同步 emit WS 消息后 await Future.delayed，
    // 期间若 provider 被 dispose，下次 read 会拿到全新 ChatNotifier（state 重置、
    // 新 _initialize 重跑），导致 emitCreate 注入的消息丢失、_initialize 抛
    // `Bad state: Tried to use ChatNotifier after dispose`。
    // 测试用例统一用 c1/a1 key，在 makeContainer 内建立长期 listener 锁定实例。
    container.listen(chatProvider((convId: 'c1', agentId: 'a1')), (_, _) {});
    return container;
  }

  /// 通过 WS 推送 MESSAGE_CREATE 注入一条消息到 state(模拟实时消息到达)。
  void emitCreate(String id, String text, {String convId = 'c1', String? parentMsgId}) {
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      d: {
        'id': id,
        'conversation_id': convId,
        'sender_type': 'user',
        'sender_id': 'u1',
        'content': {'msg_type': 'text', 'data': {'text': text}},
        'created_at': '2026-06-20T10:00:00Z',
        'parent_msg_id': ?parentMsgId,
      },
    ));
  }

  group('WS MESSAGE_CREATE 子 agent 事件过滤(parent_msg_id)', () {
    test('带 parent_msg_id 的消息不入主聊天列表', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      // 子 agent 的 reasoning/tool_calls/text 透传带 parent_msg_id(指向 task 卡片)
      emitCreate('child-1', '子 agent reasoning', parentMsgId: 'task-card-1');
      emitCreate('child-2', '子 agent tool_call', parentMsgId: 'task-card-1');
      await Future.delayed(Duration.zero);

      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });

    test('无 parent_msg_id 的主对话消息正常入列表(回归保护)', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitCreate('main-1', '主对话消息');
      await Future.delayed(Duration.zero);

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      expect(msgs.first.id, 'main-1');
    });

    /// 推送一条子 agent 审批卡(permission_card)MESSAGE_CREATE。
    /// [status] pending=待处理, approved/denied/expired=已处理。
    void emitCreateApproval(String id, {
      String status = 'pending',
      String msgType = 'permission_card',
      String parentMsgId = 'task-card-1',
      String convId = 'c1',
    }) {
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        d: {
          'id': id,
          'conversation_id': convId,
          'sender_type': 'agent',
          'sender_id': 'a1',
          'content': {
            'msg_type': msgType,
            'data': {'status': status, 'action': 'bash'},
          },
          'parent_msg_id': parentMsgId,
          'created_at': '2026-07-15T10:00:00Z',
        },
      ));
    }

    test('pending 子审批卡(permission_card)入主聊天列表', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitCreateApproval('perm-pending-1');
      await Future.delayed(Duration.zero);

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      expect(msgs.first.id, 'perm-pending-1');
    });

    test('pending 子审批卡(question_card)入主聊天列表', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitCreateApproval('qa-pending-1', msgType: 'question_card');
      await Future.delayed(Duration.zero);

      expect(container.read(chatProvider(key)).displayMessages.length, 1);
    });

    test('非 pending 子审批卡(approved)不入主聊天列表', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitCreateApproval('perm-approved-1', status: 'approved');
      await Future.delayed(Duration.zero);

      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });

    test('非 pending 子审批卡(denied)不入主聊天列表', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitCreateApproval('perm-denied-1', status: 'denied');
      await Future.delayed(Duration.zero);

      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });

    test('普通子事件(reasoning)仍不入列表(回归)', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      // emitCreate 带 parentMsgId 的 text 消息(非审批卡)应被过滤
      emitCreate('child-reasoning', '子 agent 文本', parentMsgId: 'task-card-1');
      await Future.delayed(Duration.zero);

      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });
  });

  group('WS MESSAGE_CREATE step_finish 过滤(Token 用量行)', () {
    /// 推送一条 step_finish MESSAGE_CREATE（主 session 汇总条，无 parent_msg_id）。
    void emitStepFinish(String id, {bool finished = true}) {
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        d: {
          'id': id,
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'a1',
          'content': {
            'msg_type': 'step_finish',
            'data': {
              'tokens': {'total': 12345},
              if (finished) 'finished': true,
            },
          },
          'created_at': '2026-07-17T10:00:00Z',
        },
      ));
    }

    test('finished 主循环汇总条入主聊天列表(tokens 小字,定位锚点)', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitStepFinish('sf-finished');
      await Future.delayed(Duration.zero);

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      expect(msgs.first.content['msg_type'], 'step_finish');
      expect((msgs.first.content['data'] as Map)['finished'], isTrue);
    });

    test('推理步元信息行(无 finished)不入主聊天列表', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitStepFinish('sf-process', finished: false);
      await Future.delayed(Duration.zero);

      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });

    test('普通 text 消息不受影响(回归保护)', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitCreate('plain-1', '正常消息');
      await Future.delayed(Duration.zero);

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      expect(msgs.first.id, 'plain-1');
    });
  });

  test('deleteMessages 单条:乐观移除 + 调 deleteMessage API', () async {
    final container = makeContainer();
    const key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);

    emitCreate('m1', 'one');
    emitCreate('m2', 'two');
    await Future.delayed(Duration.zero); // 让 stream listener 处理
    expect(container.read(chatProvider(key)).displayMessages.length, 2);

    when(() => api.deleteMessage('m1')).thenAnswer((_) async {});

    await notifier.deleteMessages(['m1']);

    final state = container.read(chatProvider(key));
    expect(state.displayMessages.length, 1);
    expect(state.displayMessages.any((m) => m.id == 'm1'), isFalse);
    verify(() => api.deleteMessage('m1')).called(1);
  });

  test('deleteMessages 批量:调 batchDeleteMessages API', () async {
    final container = makeContainer();
    const key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);

    emitCreate('m1', '1');
    emitCreate('m2', '2');
    await Future.delayed(Duration.zero);

    when(() => api.batchDeleteMessages(['m1', 'm2'])).thenAnswer((_) async => 2);

    await notifier.deleteMessages(['m1', 'm2']);

    expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    verify(() => api.batchDeleteMessages(['m1', 'm2'])).called(1);
  });

  test('MESSAGE_DELETE WS 事件移除对应消息(多端同步)', () async {
    final container = makeContainer();
    const key = (convId: 'c1', agentId: 'a1');
    container.read(chatProvider(key).notifier); // 触发订阅

    emitCreate('m1', '1');
    await Future.delayed(Duration.zero);
    expect(container.read(chatProvider(key)).displayMessages.length, 1);

    // 另一端删除,广播 MESSAGE_DELETE
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_DELETE',
      d: {
        'ids': ['m1'],
        'conversation_id': 'c1',
      },
    ));
    await Future.delayed(Duration.zero);

    expect(container.read(chatProvider(key)).displayMessages, isEmpty);
  });

  test('MESSAGE_DELETE 不影响其他会话的消息', () async {
    final container = makeContainer();
    const key = (convId: 'c1', agentId: 'a1');
    container.read(chatProvider(key).notifier);

    emitCreate('m1', '1', convId: 'c1');
    await Future.delayed(Duration.zero);
    expect(container.read(chatProvider(key)).displayMessages.length, 1);

    // 其他会话的删除事件不应影响本会话
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_DELETE',
      d: {
        'ids': ['other-msg'],
        'conversation_id': 'c2', // 不同会话
      },
    ));
    await Future.delayed(Duration.zero);

    expect(container.read(chatProvider(key)).displayMessages.length, 1);
  });

  test('incrementUnread: unreadCount 累加 +1（合并 newMessageCount）', () async {
    final container = makeContainer();
    const key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);
    await Future.delayed(const Duration(milliseconds: 50));

    notifier.incrementUnread();
    expect(container.read(chatProvider(key)).unreadCount, 1);

    notifier.incrementUnread();
    notifier.incrementUnread();
    expect(container.read(chatProvider(key)).unreadCount, 3);
  });

  test('markReadAtBottom: 清零 unread/separator + 清空 firstUnreadMessageId',
      () async {
    final container = makeContainer();
    const key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);
    await Future.delayed(const Duration(milliseconds: 50));

    // 模拟有未读状态
    notifier.incrementUnread();
    expect(container.read(chatProvider(key)).unreadCount, 1);

    when(() => api.markConversationRead(any())).thenAnswer((_) async => {});

    await notifier.markReadAtBottom();

    final state = container.read(chatProvider(key));
    expect(state.unreadCount, 0);
    expect(state.firstUnreadMessageId, isNull);
  });

  test('jumpToBottom: 清零 unread/separator + 清空 firstUnreadMessageId',
      () async {
    final container = makeContainer();
    const key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);
    await Future.delayed(const Duration(milliseconds: 50));

    // 模拟有未读状态：手动构造 state（通过 incrementUnread 触发）
    notifier.incrementUnread();
    expect(container.read(chatProvider(key)).unreadCount, 1);

    when(() => api.markConversationRead(any())).thenAnswer((_) async => {});

    await notifier.jumpToBottom();

    final state = container.read(chatProvider(key));
    expect(state.unreadCount, 0);
    expect(state.showUnreadSeparator, false);
    expect(state.firstUnreadMessageId, isNull); // clearFirstUnread: true 的效果
  });

  // 回归测试：jumpToBottom 在 hasMore=true 时调 getMessagesBefore 拉最新一页，
  // 与 state.displayMessages（含较老历史）合并后必须按 createdAt 降序（newest first）。
  // 历史 bug：_mergeHistory 用 [...extra, ...loaded] 假设 extra 永远更新，
  // jumpToBottom 场景下 extra 是较老历史，结果最老消息被推到 messages[0]
  // （视觉底部），用户看到「历史压在最新消息下方」。
  test('jumpToBottom: 合并后按 createdAt 降序排序（修复历史/最新顺序颠倒）',
      () async {
    final container = makeContainer();
    const key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);
    await Future.delayed(const Duration(milliseconds: 50));

    // 注入 8 条消息(各异 createdAt 升序),模拟实时到达 → 全进 liveMessages。
    // 不用 emitCreate(固定同 ts),用各异 ts 让 displayMessages 排序可确定验证。
    for (var i = 1; i <= 8; i++) {
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        d: {
          'id': 'm$i',
          'conversation_id': 'c1',
          'sender_type': 'user',
          'sender_id': 'u1',
          'content': {'msg_type': 'text', 'data': {'text': 'msg$i'}},
          'created_at': '2026-06-20T10:00:0${i}Z',
        },
      ));
    }
    await Future.delayed(const Duration(milliseconds: 50));
    expect(container.read(chatProvider(key)).displayMessages.length, 8);

    // jumpToBottom:hasMore=false(_initialize mock 返空)走 else 分支,仅清未读。
    // displayMessages 仍需正确按 createdAt 降序(newest-first)呈现 live 消息。
    when(() => api.markConversationRead(any())).thenAnswer((_) async => {});

    await notifier.jumpToBottom();

    final msgs = container.read(chatProvider(key)).displayMessages;
    expect(msgs.length, 8);
    // newest first:m8(ts 10:00:08)在 [0],m1(10:00:01)在末尾
    expect(msgs.first.id, 'm8');
    expect(msgs.last.id, 'm1');
    expect(msgs.map((m) => m.id).toList(),
        ['m8', 'm7', 'm6', 'm5', 'm4', 'm3', 'm2', 'm1']);
  });

  group('decrementUnread', () {
    test('单条减少: unreadCount -= n', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      for (var i = 0; i < 10; i++) {
        notifier.incrementUnread();
      }
      expect(container.read(chatProvider(key)).unreadCount, 10);

      notifier.decrementUnread(3);
      expect(container.read(chatProvider(key)).unreadCount, 7);
    });

    test('n=0 或负数: no-op', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      notifier.incrementUnread();
      expect(container.read(chatProvider(key)).unreadCount, 1);

      notifier.decrementUnread(0);
      expect(container.read(chatProvider(key)).unreadCount, 1);

      notifier.decrementUnread(-1);
      expect(container.read(chatProvider(key)).unreadCount, 1);
    });

    test('超减 clamp 到 0: unreadCount=2 → decrement(5) → 0', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      notifier.incrementUnread();
      notifier.incrementUnread();

      notifier.decrementUnread(5);
      expect(container.read(chatProvider(key)).unreadCount, 0);
    });

    test('减到 0 时清 firstUnreadMessageId + showUnreadSeparator', () async {
      // override mock 让 _initialize 走「有未读」分支
      // firstUnreadCreatedAt 必须非 null(_initialize assert unreadCount>0 时
      // firstUnreadCreatedAt 不为 null),用 m-unread-1 的 created_at 一致值。
      when(() => api.getUnreadInfo(any())).thenAnswer((_) async => UnreadInfo(
            unreadCount: 2,
            firstUnreadMessageId: 'm-unread-1',
            firstUnreadCreatedAt: DateTime.parse('2026-06-20T10:00:00Z'),
            hasMoreBeforeFirstUnread: false,
          ));
      when(() => api.getMessagesAfter(any(),
              after: any(named: 'after'), limit: any(named: 'limit')))
          .thenAnswer((_) async => [
                ChatMessage(
                  id: 'm-unread-1',
                  conversationId: 'c1',
                  senderType: 'agent',
                  senderId: 'a1',
                  content: {'msg_type': 'text', 'data': {'text': 'unread'}},
                  createdAt: DateTime.parse('2026-06-20T10:00:00Z'),
                ),
              ]);

      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      expect(container.read(chatProvider(key)).unreadCount, 2);
      expect(
          container.read(chatProvider(key)).firstUnreadMessageId, 'm-unread-1');
      expect(container.read(chatProvider(key)).showUnreadSeparator, isTrue);

      notifier.decrementUnread(2);

      final state = container.read(chatProvider(key));
      expect(state.unreadCount, 0);
      expect(state.firstUnreadMessageId, isNull);
      expect(state.showUnreadSeparator, isFalse);
    });
  });

  group('ChatNotifier dispose 清理 onDecide (F6)', () {
    test('构造时 onDecide 被赋值', () async {
      // 先清掉其他测试残留
      CardContentRenderer.onDecide = null;
      final notifier = ChatNotifier(
        api,
        ws,
        'conv-f6-1',
        null,
        'user-1',
      );
      // 等 _initialize 异步尾巴跑完，避免 dispose 后 _mergeHistory 还在调 state
      await Future.delayed(const Duration(milliseconds: 50));
      expect(CardContentRenderer.onDecide, isNotNull);
      notifier.dispose();
    });

    test('dispose 清空 onDecide', () async {
      CardContentRenderer.onDecide = null;
      final notifier = ChatNotifier(
        api,
        ws,
        'conv-f6-2',
        null,
        'user-1',
      );
      await Future.delayed(const Duration(milliseconds: 50));
      expect(CardContentRenderer.onDecide, isNotNull);
      notifier.dispose();
      expect(CardContentRenderer.onDecide, isNull);
    });
  });

  group('MESSAGE_READ 多端同步', () {
    test('收到 MESSAGE_READ 刷 unreadCount + 清 firstUnread(全读场景)', () async {
      // 构造一个有未读的会话:getUnreadInfo 返 unreadCount=3 + firstUnread
      when(() => api.getUnreadInfo(any())).thenAnswer((_) async => UnreadInfo(
            unreadCount: 3,
            firstUnreadMessageId: 'm-unread-1',
            firstUnreadCreatedAt: DateTime.utc(2026, 7, 5),
          ));
      when(() => api.getMessagesAfter(any(),
              limit: any(named: 'limit'), after: any(named: 'after')))
          .thenAnswer((_) async => <ChatMessage>[]);

      final notifier = ChatNotifier(
        api,
        ws,
        'conv-mr',
        null,
        'user-1',
      );
      await Future.delayed(const Duration(milliseconds: 50));
      expect(notifier.state.unreadCount, 3);
      expect(notifier.state.firstUnreadMessageId, 'm-unread-1');

      // 模拟 A 设备已读全部 → server 广播 MESSAGE_READ
      ws.emitMessageRead(WSMessage(
        op: 0,
        t: 'MESSAGE_READ',
        d: {
          'conversation_id': 'conv-mr',
          'message_ids': ['m-unread-1', 'm-unread-2', 'm-unread-3'],
          'unread_count': 0,
          'read_at': DateTime.utc(2026, 7, 6).toIso8601String(),
        },
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.state.unreadCount, 0);
      expect(notifier.state.firstUnreadMessageId, isNull);
      expect(notifier.state.showUnreadSeparator, isFalse);
      notifier.dispose();
    });

    test('MESSAGE_READ 其他会话事件被忽略(不影响本会话)', () async {
      when(() => api.getUnreadInfo(any())).thenAnswer((_) async => UnreadInfo(
            unreadCount: 2,
            firstUnreadMessageId: 'm1',
            firstUnreadCreatedAt: DateTime.utc(2026, 7, 5),
          ));
      when(() => api.getMessagesAfter(any(),
              limit: any(named: 'limit'), after: any(named: 'after')))
          .thenAnswer((_) async => <ChatMessage>[]);

      final notifier = ChatNotifier(
        api,
        ws,
        'conv-self',
        null,
        'user-1',
      );
      await Future.delayed(const Duration(milliseconds: 50));

      // 别的会话事件
      ws.emitMessageRead(WSMessage(
        op: 0,
        t: 'MESSAGE_READ',
        d: {
          'conversation_id': 'conv-OTHER',
          'message_ids': ['x'],
          'unread_count': 0,
          'read_at': DateTime.utc(2026, 7, 6).toIso8601String(),
        },
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // 本会话状态不变
      expect(notifier.state.unreadCount, 2);
      expect(notifier.state.firstUnreadMessageId, 'm1');
      notifier.dispose();
    });
  });

  group('pendingQuote state management', () {
    test('setPendingQuote / clearPendingQuote 状态切换', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      // 初始为 null
      expect(container.read(chatProvider(key)).pendingQuote, isNull);

      // 设置后通过 state 读取到
      notifier.setPendingQuote(const Quote(
        messageId: 'm_q',
        senderType: 'user',
        senderId: 'u1',
        senderName: 'alice',
        msgType: 'text',
        preview: '原文',
      ));
      final stateAfterSet = container.read(chatProvider(key));
      expect(stateAfterSet.pendingQuote, isNotNull);
      expect(stateAfterSet.pendingQuote!.messageId, 'm_q');

      // 清空后回到 null
      notifier.clearPendingQuote();
      expect(container.read(chatProvider(key)).pendingQuote, isNull);
    });

    test('send 时合并 pendingQuote 到 content.data.quote 后清空', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      // 捕获 api.sendMessage 收到的 content
      Map<String, dynamic>? captured;
      when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
        captured = inv.positionalArguments[1] as Map<String, dynamic>;
        return (
          messageId: 'srv_1',
          createdAt: DateTime.utc(2026, 7, 7),
        );
      });

      notifier.setPendingQuote(const Quote(
        messageId: 'm_q',
        senderType: 'user',
        senderId: 'u1',
        senderName: 'alice',
        msgType: 'text',
        preview: '原文',
      ));

      await notifier.sendText('回复正文');

      // 验证: 发送的 content.data.quote 是完整 snapshot
      // (本地乐观消息渲染需要 preview + senderName 立即可见,
      //  server enrichQuote 仍会用权威值覆盖,协议安全性不变)
      expect(captured, isNotNull);
      expect(captured!['msg_type'], 'text');
      final data = captured!['data'] as Map<String, dynamic>;
      expect(data['text'], '回复正文');
      expect(data['quote'], {
        'message_id': 'm_q',
        'sender_type': 'user',
        'sender_id': 'u1',
        'sender_name': 'alice',
        'msg_type': 'text',
        'preview': '原文',
      });

      // 验证: 发送完自动清空 pendingQuote
      expect(container.read(chatProvider(key)).pendingQuote, isNull);
    });

    test('无 pendingQuote 时 send 不向 content.data 写 quote 键', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      Map<String, dynamic>? captured;
      when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
        captured = inv.positionalArguments[1] as Map<String, dynamic>;
        return (
          messageId: 'srv_2',
          createdAt: DateTime.utc(2026, 7, 7),
        );
      });

      // 不设置 pendingQuote,直接发送
      await notifier.sendText('普通消息');

      expect(captured, isNotNull);
      final data = captured!['data'] as Map<String, dynamic>;
      expect(data['text'], '普通消息');
      expect(data.containsKey('quote'), isFalse);
    });

    test('clearPendingQuote 在 pendingQuote 已为 null 时是 no-op(不触发 state 写入)',
        () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      final before = container.read(chatProvider(key));
      expect(before.pendingQuote, isNull); // precondition

      notifier.clearPendingQuote(); // pendingQuote 已为 null,应短路

      final after = container.read(chatProvider(key));
      // 同一引用 = StateNotifier 未触发 state 写入(短路保护契约)
      expect(identical(before, after), isTrue);
    });

    test('sendText 失败时 pendingQuote 也被清空(失败也清契约)', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      when(() => api.sendMessage(any(), any()))
          .thenThrow(Exception('network down'));

      notifier.setPendingQuote(const Quote(
        messageId: 'm_q',
        senderType: 'user',
        senderId: 'u1',
        senderName: '洛羽',
        msgType: 'text',
        preview: '原文',
      ));
      expect(container.read(chatProvider(key)).pendingQuote, isNotNull);

      await notifier.sendText('回复');

      expect(container.read(chatProvider(key)).pendingQuote, isNull);
    });

    test('sendFile 时合并 pendingQuote 到 content.data.quote 后清空', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      // 捕获 api.sendMessage 收到的 content
      Map<String, dynamic>? captured;
      when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
        captured = inv.positionalArguments[1] as Map<String, dynamic>;
        return (
          messageId: 'srv_f1',
          createdAt: DateTime.utc(2026, 7, 7),
        );
      });

      notifier.setPendingQuote(const Quote(
        messageId: 'm_q',
        senderType: 'user',
        senderId: 'u1',
        senderName: '洛羽',
        msgType: 'text',
        preview: '原文',
      ));

      await notifier.sendFile('f1', MsgType.file,
          filename: 'x.png', mimeType: 'image/png', fileSize: 1024);

      // 验证: 文件消息的 content.data.quote 是完整 snapshot
      // (与 sendText 对齐,本地乐观渲染需要完整字段)
      expect(captured, isNotNull);
      expect(captured!['msg_type'], 'file');
      final data = captured!['data'] as Map<String, dynamic>;
      expect(data['file_id'], 'f1');
      expect(data['filename'], 'x.png');
      expect(data['quote'], {
        'message_id': 'm_q',
        'sender_type': 'user',
        'sender_id': 'u1',
        'sender_name': '洛羽',
        'msg_type': 'text',
        'preview': '原文',
      });

      // 验证: 发送完自动清空 pendingQuote,不泄漏到下次文本发送
      expect(container.read(chatProvider(key)).pendingQuote, isNull);
    });

    test('sendFile 失败时 pendingQuote 也被清空(失败也清契约)', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      when(() => api.sendMessage(any(), any()))
          .thenThrow(Exception('network down'));

      notifier.setPendingQuote(const Quote(
        messageId: 'm_q',
        senderType: 'user',
        senderId: 'u1',
        senderName: '洛羽',
        msgType: 'text',
        preview: '原文',
      ));
      expect(container.read(chatProvider(key)).pendingQuote, isNotNull);

      await notifier.sendFile('f1', MsgType.file, filename: 'x.png');

      expect(container.read(chatProvider(key)).pendingQuote, isNull);
    });
  });

  group('sendMixed 图文混合消息', () {
    test('sendMixed: 有文字时载荷为顶层 text + items 图片条目', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      final sent = <Map<String, dynamic>>[];
      when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
        sent.add(inv.positionalArguments[1] as Map<String, dynamic>);
        return (
          messageId: 'srv-1',
          createdAt: DateTime.parse('2026-08-28T00:00:00Z'),
        );
      });

      await notifier.sendMixed('看这张图', 'file-1',
          filename: 'a.png', mimeType: 'image/png', fileSize: 10);

      expect(sent, hasLength(1));
      expect(sent.first['msg_type'], 'mixed');
      final data = sent.first['data'] as Map<String, dynamic>;
      expect(data['text'], '看这张图');
      // brief 原断言漏 mime_type,与其传入的 mimeType: 'image/png' 及同构实现
      // (sendFile 同样条件写入 mime_type)矛盾,此处按实现合同补全。
      expect(data['items'], [
        {
          'type': 'image',
          'file_id': 'file-1',
          'filename': 'a.png',
          'mime_type': 'image/png',
        },
      ]);
    });

    test('sendMixed: 无文字时省略 text 字段', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      final sent = <Map<String, dynamic>>[];
      when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
        sent.add(inv.positionalArguments[1] as Map<String, dynamic>);
        return (
          messageId: 'srv-2',
          createdAt: DateTime.parse('2026-08-28T00:00:00Z'),
        );
      });

      await notifier.sendMixed('', 'file-2');

      final data = sent.first['data'] as Map<String, dynamic>;
      expect(data.containsKey('text'), isFalse);
      expect(data['items'], [
        {'type': 'image', 'file_id': 'file-2'},
      ]);
    });
  });

  group('mergeJumpedContext', () {
    /// 构造一条 ChatMessage,id/createdAt 可控。
    ChatMessage mkMsg(String id, DateTime createdAt) {
      return ChatMessage(
        id: id,
        conversationId: 'c1',
        senderType: 'user',
        senderId: 'u1',
        content: const {'msg_type': 'text', 'data': {'text': 'x'}},
        createdAt: createdAt,
      );
    }

    test('本地未命中:target + before + after 全部合并,按时间倒序', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);

      // 让 state 有 1 条已有消息 m0(最早,WS 注入固定 createdAt=2026-06-20)
      emitCreate('m0', 'oldest');
      await Future.delayed(Duration.zero);

      // target=m3,before=[m1,m2](倒序,最新在前),after=[m4](正序)
      // 已有 m0(2026-06-20,最早),合并后按 createdAt 倒序:
      // m4 > m3 > m2 > m1 > m0
      final ctx = MessageContext(
        target: mkMsg('m3', DateTime.parse('2026-07-01T10:03:00Z')),
        before: [
          mkMsg('m2', DateTime.parse('2026-07-01T10:02:00Z')),
          mkMsg('m1', DateTime.parse('2026-07-01T10:01:00Z')),
        ],
        after: [
          mkMsg('m4', DateTime.parse('2026-07-01T10:04:00Z')),
        ],
      );

      notifier.mergeJumpedContext(ctx);

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.map((m) => m.id).toList(), ['m4', 'm3', 'm2', 'm1', 'm0']);
    });

    test('去重:已存在的 id 不重复加入', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);

      // 已有 m3(通过 WS 注入,createdAt 固定 2026-06-20)
      emitCreate('m3', 'three');
      await Future.delayed(Duration.zero);
      expect(container.read(chatProvider(key)).displayMessages.length, 1);

      // 合并的 ctx 又包含 m3(模拟 server 返回了已存在的消息)
      final ctx = MessageContext(
        target: mkMsg('m3', DateTime.parse('2026-06-20T10:00:00Z')),
        before: const [],
        after: const [],
      );

      notifier.mergeJumpedContext(ctx);

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      expect(msgs.first.id, 'm3');
    });

    test('全部已存在时不触发 state 写入(返回前 messages 不变)', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);

      emitCreate('m3', 'three');
      await Future.delayed(Duration.zero);

      final stateBefore = container.read(chatProvider(key));
      // identical 用来确认没有 rebuild
      int rebuildCount = 0;
      container.listen(chatProvider(key), (prev, next) {
        if (!identical(prev, next)) rebuildCount++;
      });

      final ctx = MessageContext(
        target: mkMsg('m3', DateTime.parse('2026-06-20T10:00:00Z')),
        before: const [],
        after: const [],
      );
      notifier.mergeJumpedContext(ctx);

      // 让 listen 回调有机会执行
      await Future.delayed(Duration.zero);
      expect(rebuildCount, 0);
      expect(container.read(chatProvider(key)), same(stateBefore));
    });
  });

  group('modelOverride', () {
    test('selectModel 设置 modelOverride', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      notifier.selectModel(const ModelOverride(
        providerID: 'zhipuai', modelID: 'glm-5.2-airx',
      ));

      final state = container.read(chatProvider(key));
      expect(state.modelOverride, isNotNull);
      expect(state.modelOverride!.providerID, 'zhipuai');
      expect(state.modelOverride!.modelID, 'glm-5.2-airx');
    });

    test('sendText 注入 _model 到 content.data(有 modelOverride)', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      Map<String, dynamic>? captured;
      when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
        captured = inv.positionalArguments[1] as Map<String, dynamic>;
        return (messageId: 'srv_m1', createdAt: DateTime.utc(2026, 7, 17));
      });

      notifier.selectModel(const ModelOverride(
        providerID: 'zhipuai', modelID: 'glm-5.2-airx',
      ));
      await notifier.sendText('你好');

      expect(captured, isNotNull);
      final data = captured!['data'] as Map<String, dynamic>;
      expect(data['_model'], {
        'provider_id': 'zhipuai',
        'model_id': 'glm-5.2-airx',
      });
    });

    test('sendText 无 modelOverride 时不注入 _model', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      Map<String, dynamic>? captured;
      when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
        captured = inv.positionalArguments[1] as Map<String, dynamic>;
        return (messageId: 'srv_m2', createdAt: DateTime.utc(2026, 7, 17));
      });

      await notifier.sendText('你好');

      expect(captured, isNotNull);
      final data = captured!['data'] as Map<String, dynamic>;
      expect(data.containsKey('_model'), isFalse);
    });
  });

  group('WS MESSAGE_UPDATE 子审批卡终态移除', () {
    void emitCreateApprovalLocal(String id, {String convId = 'c1'}) {
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        d: {
          'id': id,
          'conversation_id': convId,
          'sender_type': 'agent',
          'sender_id': 'a1',
          'content': {
            'msg_type': 'permission_card',
            'data': {'status': 'pending', 'action': 'bash'},
          },
          'parent_msg_id': 'task-card-1',
          'created_at': '2026-07-15T10:00:00Z',
        },
      ));
    }

    void emitUpdateApproval(String id, String newStatus, {String convId = 'c1'}) {
      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        d: {
          'message_id': id,
          'conversation_id': convId,
          'content': {
            'msg_type': 'permission_card',
            'data': {'status': newStatus, 'action': 'bash'},
          },
        },
      ));
    }

    test('pending→approved 从列表移除', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitCreateApprovalLocal('perm-pend-1');
      await Future.delayed(Duration.zero);
      expect(container.read(chatProvider(key)).displayMessages.length, 1);

      emitUpdateApproval('perm-pend-1', 'approved');
      await Future.delayed(Duration.zero);
      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });

    test('pending→denied 从列表移除', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      emitCreateApprovalLocal('perm-pend-2');
      await Future.delayed(Duration.zero);

      emitUpdateApproval('perm-pend-2', 'denied');
      await Future.delayed(Duration.zero);
      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });

    test('普通消息 MESSAGE_UPDATE 走 content 替换不移除', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      // 先建一条顶层 text 消息
      emitCreate('main-msg-1', '原文');
      await Future.delayed(Duration.zero);
      expect(container.read(chatProvider(key)).displayMessages.length, 1);

      // task 卡片状态变更(working→completed)的 MESSAGE_UPDATE
      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        d: {
          'message_id': 'main-msg-1',
          'conversation_id': 'c1',
          'content': {
            'msg_type': 'text',
            'data': {'text': '更新后'},
          },
        },
      ));
      await Future.delayed(Duration.zero);

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1); // 不移除
      expect(((msgs.first.content['data'] as Map)['text']) as String, '更新后'); // content 被替换
    });
  });

  group('SESSION_META_UPDATE 实时刷新 sessionMeta', () {
    /// 验证 plugin 写完 session_meta 后,server 广播 SESSION_META_UPDATE,
    /// chatProvider 监听后整体替换 chatState.sessionMeta,
    /// SessionMetaStrip / EnvMetaStrip 实时刷新。
    /// 不再依赖 agent 消息触发的 2s 防抖拉取(原路径只能拉到 plugin 上次写入的快照)。
    test('SESSION_META_UPDATE 整体替换 sessionMeta + 同步 mode/model/git_branch',
        () async {
      final notifier = ChatNotifier(
        api,
        ws,
        'conv-meta',
        null,
        'user-1',
      );
      // 初始 sessionMeta 由 _initialize 设置(测试中 getConversation 未 mock 返 null,
      // state.sessionMeta = null,符合测试起点)。
      await Future.delayed(const Duration(milliseconds: 30));

      // 模拟 plugin PATCH 后 server 广播
      ws.emitSessionMetaUpdate(WSMessage(
        op: 0,
        t: 'SESSION_META_UPDATE',
        d: {
          'conv_id': 'conv-meta',
          'session_meta': {
            'mode': 'build',
            'model_id': 'glm-5.2',
            'provider_id': 'zhipuai',
            'variant': 'default',
            'git_branch': 'feat/x',
          },
        },
      ));
      await Future.delayed(const Duration(milliseconds: 30));

      expect(notifier.state.sessionMeta, isNotNull);
      expect(notifier.state.sessionMeta!.gitBranch, 'feat/x');
      expect(notifier.state.sessionMeta!.mode, 'build');
      expect(notifier.state.sessionMeta!.modelId, 'glm-5.2');
      notifier.dispose();
    });

    test('SESSION_META_UPDATE 忽略其他会话事件', () async {
      final notifier = ChatNotifier(
        api,
        ws,
        'conv-self',
        null,
        'user-1',
      );
      await Future.delayed(const Duration(milliseconds: 30));

      // 别的会话事件
      ws.emitSessionMetaUpdate(WSMessage(
        op: 0,
        t: 'SESSION_META_UPDATE',
        d: {
          'conv_id': 'conv-other',
          'session_meta': {
            'mode': 'plan',
            'cwd': '/other/path',
            'git_branch': 'other',
          },
        },
      ));
      await Future.delayed(const Duration(milliseconds: 30));

      // 本会话 state 不变
      expect(notifier.state.sessionMeta, isNull);
      notifier.dispose();
    });

    test('OC 优先:server mode 与 modeOverride 不一致 → 清除 override', () async {
      final notifier = ChatNotifier(
        api,
        ws,
        'conv-oc',
        null,
        'user-1',
      );
      await Future.delayed(const Duration(milliseconds: 30));
      // 先建初始 sessionMeta(mode=plan)
      ws.emitSessionMetaUpdate(WSMessage(
        op: 0,
        t: 'SESSION_META_UPDATE',
        d: {
          'conv_id': 'conv-oc',
          'session_meta': {
            'mode': 'plan',
            'model_id': 'm',
            'provider_id': 'p',
          },
        },
      ));
      await Future.delayed(const Duration(milliseconds: 30));
      expect(notifier.state.sessionMeta!.mode, 'plan');

      // 用户手动切到 build(本地 override)
      notifier.toggleMode(); // plan → build
      expect(notifier.state.modeOverride, 'build');

      // server 回流 mode=plan(OC 实际生效)→ 清 override
      ws.emitSessionMetaUpdate(WSMessage(
        op: 0,
        t: 'SESSION_META_UPDATE',
        d: {
          'conv_id': 'conv-oc',
          'session_meta': {
            'mode': 'plan',
            'model_id': 'm',
            'provider_id': 'p',
          },
        },
      ));
      await Future.delayed(const Duration(milliseconds: 30));

      expect(notifier.state.modeOverride, isNull);
      expect(notifier.state.sessionMeta!.mode, 'plan');
      notifier.dispose();
    });

    test('缺 session_meta 字段的事件被忽略(防 NPE)', () async {
      final notifier = ChatNotifier(
        api,
        ws,
        'conv-bad',
        null,
        'user-1',
      );
      await Future.delayed(const Duration(milliseconds: 30));

      // payload 缺 session_meta 字段(异常情况)
      ws.emitSessionMetaUpdate(WSMessage(
        op: 0,
        t: 'SESSION_META_UPDATE',
        d: {
          'conv_id': 'conv-bad',
        },
      ));
      await Future.delayed(const Duration(milliseconds: 30));

      expect(notifier.state.sessionMeta, isNull);
      notifier.dispose();
    });
  });

  group('聚合卡增量合并回归(分卡 bug)', () {
    test('建卡空 elements + append 增量 → 元素被填充,不空白', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);

      // 1. 建聚合卡:MESSAGE_CREATE, elements=[] (plugin ensureCard)
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        d: {
          'id': 'agg-1',
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'a1',
          'content': {
            'msg_type': 'aggregate_card',
            'silent': true,
            'data': {
              'schema_ver': 1,
              'state': 'generating',
              'elements': [],
            },
          },
          'created_at': '2026-08-08T10:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      var msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.where((m) => m.id == 'agg-1').length, 1,
          reason: '聚合卡 MESSAGE_CREATE 应入列表');

      // 2. append 增量:MESSAGE_UPDATE {op:"append", element}
      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        d: {
          'conversation_id': 'c1',
          'message_id': 'agg-1',
          'content': {
            'msg_type': 'aggregate_card',
            'data': {
              'op': 'append',
              'element': {
                'type': 'markdown',
                'element_id': 'markdown_1',
                'data': {'text': '正文内容'},
              },
            },
          },
        },
      ));
      await Future.delayed(Duration.zero);

      msgs = container.read(chatProvider(key)).displayMessages;
      final agg = msgs.firstWhere((m) => m.id == 'agg-1');
      final elements =
          ((agg.content['data'] as Map)['elements'] as List).toList();
      expect(elements.length, 1, reason: 'append 增量应合并进 elements');
      expect((elements[0] as Map)['element_id'], 'markdown_1');
      expect(((elements[0] as Map)['data'] as Map)['text'], '正文内容');
    });
  });

  group('聚合卡 silent 翻转 MESSAGE_UPDATE 反映到 content(未读清除前提)', () {
    test('翻转广播后 chatProvider content.silent true→false', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      // 聚合卡创建(silent=true)
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        d: {
          'id': 'agg-1',
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'a1',
          'content': {
            'msg_type': 'aggregate_card',
            'data': {'state': 'generating', 'elements': const []},
            'silent': true,
          },
          'created_at': '2026-06-20T10:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);
      expect(
        container
            .read(chatProvider(key))
            .displayMessages
            .firstWhere((m) => m.id == 'agg-1')
            .content['silent'],
        true,
        reason: '创建时 silent=true',
      );

      // 回合结束翻转:set_silent delta 广播
      ws.emitUpdate(WSMessage(
        op: 0,
        t: 'MESSAGE_UPDATE',
        d: {
          'conversation_id': 'c1',
          'message_id': 'agg-1',
          'content': {
            'msg_type': 'aggregate_card',
            'data': {'op': 'set_silent', 'silent': false},
          },
        },
      ));
      await Future.delayed(Duration.zero);

      expect(
        container
            .read(chatProvider(key))
            .displayMessages
            .firstWhere((m) => m.id == 'agg-1')
            .content['silent'],
        false,
        reason: '翻转后 silent=false(未读清除前提)',
      );
    });
  });

  group('hasUnread 分支补拉 before(ba6d289)', () {
    test('firstUnread 之前的聚合卡经 getMessagesBefore 补拉,不缺失', () async {
      // 有未读:firstUnread 是 last 卡,分卡 first 卡在它之前
      when(() => api.getUnreadInfo(any())).thenAnswer((_) async => UnreadInfo(
            unreadCount: 1,
            firstUnreadMessageId: 'last-card',
            firstUnreadCreatedAt: DateTime.utc(2026, 7, 6),
          ));
      // getMessagesAfter 只返 firstUnread(last 卡)
      when(() => api.getMessagesAfter(any(),
              limit: any(named: 'limit'), after: any(named: 'after')))
          .thenAnswer((_) async => [
                ChatMessage(
                  id: 'last-card',
                  conversationId: 'c1',
                  senderType: 'agent',
                  senderId: 'a1',
                  content: {'msg_type': 'text', 'data': {'text': 'last'}},
                  createdAt: DateTime.utc(2026, 7, 6),
                ),
              ]);
      // getMessagesBefore 补拉最新上下文(含 first 卡)
      when(() => api.getMessagesBefore(any(),
              limit: any(named: 'limit'), before: any(named: 'before')))
          .thenAnswer((_) async => [
                ChatMessage(
                  id: 'first-card',
                  conversationId: 'c1',
                  senderType: 'agent',
                  senderId: 'a1',
                  content: {'msg_type': 'text', 'data': {'text': 'first'}},
                  createdAt: DateTime.utc(2026, 7, 5),
                ),
                ChatMessage(
                  id: 'last-card',
                  conversationId: 'c1',
                  senderType: 'agent',
                  senderId: 'a1',
                  content: {'msg_type': 'text', 'data': {'text': 'last'}},
                  createdAt: DateTime.utc(2026, 7, 6),
                ),
              ]);

      final notifier = ChatNotifier(api, ws, 'c1', null, 'u1');
      await Future.delayed(const Duration(milliseconds: 100));

      // 合并后 first + last 都在(去重保留 after 版 last)
      final ids = notifier.state.displayMessages.map((m) => m.id).toSet();
      expect(ids, contains('first-card'),
          reason: 'hasUnread 分支补拉 firstUnread 之前的卡');
      expect(ids, contains('last-card'));
      // develop displayMessages 是 newest-first:first=最新(last 卡),last=最老(first 卡)
      final msgs = notifier.state.displayMessages;
      expect(msgs.first.id, 'last-card');
      expect(msgs.last.id, 'first-card');
      notifier.dispose();
    });
  });

  group('_initialize 拉取时生成中聚合卡归属 live', () {
    ChatMessage aggregateCard({
      required String id,
      String state = 'generating',
      bool silent = false,
      List<Map<String, dynamic>>? elements,
    }) {
      return ChatMessage.fromJson({
        'id': id,
        'conversation_id': 'c1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'aggregate_card',
          'data': {
            'state': state,
            'elements': elements ??
                [
                  {
                    'type': 'reasoning',
                    'element_id': 'r1',
                    'data': {'text': '思考'},
                  },
                ],
          },
          if (silent) 'silent': true,
        },
        'created_at': '2026-06-20T10:05:00Z',
      });
    }

    test('noUnread 分支拉到 generating 非空聚合卡 → 进 live', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      // 覆盖 setUp 的空 mock:注入一条生成中聚合卡(最新)
      when(() => api.getMessagesBefore(any(),
              limit: any(named: 'limit'), before: any(named: 'before')))
          .thenAnswer((_) async => [
                aggregateCard(id: 'agg1'),
              ]);
      container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(chatProvider(key));
      expect(state.liveMessages.map((m) => m.id), contains('agg1'),
          reason: '生成中聚合卡应进 live sliver');
      expect(state.historyMessages.map((m) => m.id), isNot(contains('agg1')),
          reason: '生成中聚合卡不应进 history');
    });

    test('done 聚合卡 → 进 history,不进 live', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      when(() => api.getMessagesBefore(any(),
              limit: any(named: 'limit'), before: any(named: 'before')))
          .thenAnswer((_) async => [
                aggregateCard(id: 'agg1', state: 'done', silent: false),
              ]);
      container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(chatProvider(key));
      expect(state.historyMessages.map((m) => m.id), contains('agg1'),
          reason: 'done 聚合卡应进 history');
      expect(state.liveMessages.map((m) => m.id), isNot(contains('agg1')));
    });

    test('generating 空卡(elements 空)→ 不进 live', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      when(() => api.getMessagesBefore(any(),
              limit: any(named: 'limit'), before: any(named: 'before')))
          .thenAnswer((_) async => [
                aggregateCard(id: 'agg1', elements: const []),
              ]);
      container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(chatProvider(key));
      expect(state.liveMessages.map((m) => m.id), isNot(contains('agg1')),
          reason: '空卡不进 live(靠 WS 增量填充)');
    });

    test('generating 卡非最新一条(后面还有更新消息)→ 不进 live', () async {
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      when(() => api.getMessagesBefore(any(),
              limit: any(named: 'limit'), before: any(named: 'before')))
          .thenAnswer((_) async => [
                aggregateCard(id: 'agg1'),
                ChatMessage.fromJson({
                  'id': 'newer',
                  'conversation_id': 'c1',
                  'sender_type': 'user',
                  'sender_id': 'u1',
                  'content': {'msg_type': 'text', 'data': {'text': '更新的消息'}},
                  'created_at': '2026-06-20T10:06:00Z',
                }),
              ]);
      container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(chatProvider(key));
      expect(state.liveMessages.map((m) => m.id), isNot(contains('agg1')),
          reason: '仅最新一条 generating 卡进 live');
    });
  });

  group('未读定位兼容(generating 卡不影响 firstUnread 锚点)', () {
    test('hasUnread 分支:firstUnread 是 done 聚合卡 → 留在 history 可定位',
        () async {
      // 清掉 setUp 的 stub,重建本测试专属 mock(hasUnread 分支)
      reset(api);
      when(() => api.getMessages(any(),
              limit: any(named: 'limit'), offset: any(named: 'offset')))
          .thenAnswer((_) async => <ChatMessage>[]);
      when(() => api.getUnreadInfo(any())).thenAnswer((_) async => UnreadInfo(
            unreadCount: 1,
            firstUnreadMessageId: 'agg-done',
            firstUnreadCreatedAt: DateTime.parse('2026-06-20T10:04:00Z'),
            hasMoreBeforeFirstUnread: false,
          ));
      when(() => api.getMessagesAfter(any(),
              after: any(named: 'after'), limit: any(named: 'limit')))
          .thenAnswer((_) async => [
                ChatMessage.fromJson({
                  'id': 'agg-done',
                  'conversation_id': 'c1',
                  'sender_type': 'agent',
                  'sender_id': 'a1',
                  'content': {
                    'msg_type': 'aggregate_card',
                    'data': {
                      'state': 'done',
                      'elements': [
                        {
                          'type': 'markdown',
                          'element_id': 'm1',
                          'data': {'text': '最终'},
                        },
                      ],
                    },
                  },
                  'created_at': '2026-06-20T10:04:00Z',
                }),
              ]);
      when(() => api.getMessagesBefore(any(),
              limit: any(named: 'limit'), before: any(named: 'before')))
          .thenAnswer((_) async => [
                ChatMessage.fromJson({
                  'id': 'agg-gen',
                  'conversation_id': 'c1',
                  'sender_type': 'agent',
                  'sender_id': 'a1',
                  'content': {
                    'msg_type': 'aggregate_card',
                    'data': {
                      'state': 'generating',
                      'elements': [
                        {
                          'type': 'reasoning',
                          'element_id': 'r1',
                          'data': {'text': '思考'},
                        },
                      ],
                    },
                  },
                  'created_at': '2026-06-20T10:05:00Z',
                }),
              ]);
      final container = makeContainer();
      const key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      final state = container.read(chatProvider(key));
      expect(state.firstUnreadMessageId, 'agg-done');
      expect(state.historyMessages.map((m) => m.id), contains('agg-done'),
          reason: 'done 聚合卡(未读锚点)留在 history,定位逻辑可找到');
      expect(state.liveMessages.map((m) => m.id), contains('agg-gen'),
          reason: '更新的 generating 卡进 live');
      // displayMessages 按 id 去重,不双显
      expect(state.displayMessages.map((m) => m.id).toSet().length,
          state.displayMessages.length);
    });
  });
}
