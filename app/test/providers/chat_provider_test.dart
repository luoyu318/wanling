import 'package:app/models/ws_message.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart';
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
    // _initialize 现在调 getUnreadInfo + getMessagesBefore（无未读路径）。
    // 兜底 catch 分支仍可能调 getMessages，保留 mock。
    when(() => api.getUnreadInfo(any())).thenAnswer((_) async => {
          'unread_count': 0,
          'first_unread_message_id': '',
          'first_unread_created_at': null,
        });
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => []);
    when(() => api.getMessages(any(),
            limit: any(named: 'limit'), offset: any(named: 'offset')))
        .thenAnswer((_) async => []);
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
    container.listen(chatProvider((convId: 'c1', agentId: 'a1')), (_, __) {});
    return container;
  }

  /// 通过 WS 推送 MESSAGE_CREATE 注入一条消息到 state(模拟实时消息到达)。
  void emitCreate(String id, String text, {String convId = 'c1'}) {
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
      },
    ));
  }

  test('deleteMessages 单条:乐观移除 + 调 deleteMessage API', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);

    emitCreate('m1', 'one');
    emitCreate('m2', 'two');
    await Future.delayed(Duration.zero); // 让 stream listener 处理
    expect(container.read(chatProvider(key)).messages.length, 2);

    when(() => api.deleteMessage('m1')).thenAnswer((_) async {});

    await notifier.deleteMessages(['m1']);

    final state = container.read(chatProvider(key));
    expect(state.messages.length, 1);
    expect(state.messages.any((m) => m.id == 'm1'), isFalse);
    verify(() => api.deleteMessage('m1')).called(1);
  });

  test('deleteMessages 批量:调 batchDeleteMessages API', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);

    emitCreate('m1', '1');
    emitCreate('m2', '2');
    await Future.delayed(Duration.zero);

    when(() => api.batchDeleteMessages(['m1', 'm2'])).thenAnswer((_) async => 2);

    await notifier.deleteMessages(['m1', 'm2']);

    expect(container.read(chatProvider(key)).messages, isEmpty);
    verify(() => api.batchDeleteMessages(['m1', 'm2'])).called(1);
  });

  test('MESSAGE_DELETE WS 事件移除对应消息(多端同步)', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    container.read(chatProvider(key).notifier); // 触发订阅

    emitCreate('m1', '1');
    await Future.delayed(Duration.zero);
    expect(container.read(chatProvider(key)).messages.length, 1);

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

    expect(container.read(chatProvider(key)).messages, isEmpty);
  });

  test('MESSAGE_DELETE 不影响其他会话的消息', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    container.read(chatProvider(key).notifier);

    emitCreate('m1', '1', convId: 'c1');
    await Future.delayed(Duration.zero);
    expect(container.read(chatProvider(key)).messages.length, 1);

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

    expect(container.read(chatProvider(key)).messages.length, 1);
  });

  test('incrementUnread: unreadCount 累加 +1（合并 newMessageCount）', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
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
    final key = (convId: 'c1', agentId: 'a1');
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
    final key = (convId: 'c1', agentId: 'a1');
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
  // 与 state.messages（含较老历史）合并后必须按 createdAt 降序（newest first）。
  // 历史 bug：_mergeHistory 用 [...extra, ...loaded] 假设 extra 永远更新，
  // jumpToBottom 场景下 extra 是较老历史，结果最老消息被推到 messages[0]
  // （视觉底部），用户看到「历史压在最新消息下方」。
  test('jumpToBottom: 合并后按 createdAt 降序排序（修复历史/最新顺序颠倒）',
      () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);
    await Future.delayed(const Duration(milliseconds: 50));

    // 模拟首屏预加载后的 state：6 条较老历史（T1..T6）+ WS 推送的 2 条最新消息（T7, T8）
    // emitCreate 用固定 created_at 升序注入，state.messages 内部已是 newest first
    for (var i = 1; i <= 8; i++) {
      emitCreate('m$i', 'msg$i');
    }
    await Future.delayed(const Duration(milliseconds: 50));
    expect(container.read(chatProvider(key)).messages.length, 8);

    // jumpToBottom 会拉最新 5 条（loaded = m4..m8），state.messages 中 extra = m1..m3（最老）
    when(() => api.getMessagesBefore(any(), limit: any(named: 'limit'),
            before: any(named: 'before')))
        .thenAnswer((_) async => [
              // 服务端返回 ASC（最老在前），ChatNotifier 内 _parseMessages 不反转
              // 但 _mergeHistory 排序后会归位
              for (var i = 4; i <= 8; i++)
                {
                  'id': 'm$i',
                  'conversation_id': 'c1',
                  'sender_type': 'user',
                  'sender_id': 'u1',
                  'content': {'msg_type': 'text', 'data': {'text': 'msg$i'}},
                  'created_at': '2026-06-20T10:00:0${i}Z',
                },
            ]);
    when(() => api.markConversationRead(any())).thenAnswer((_) async => {});

    await notifier.jumpToBottom();

    final msgs = container.read(chatProvider(key)).messages;
    expect(msgs.length, 8);
    // newest first：m8 在 [0]，m1 在 [7]
    expect(msgs.first.id, 'm8');
    expect(msgs.last.id, 'm1');
  });

  group('decrementUnread', () {
    test('单条减少: unreadCount -= n', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
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
      final key = (convId: 'c1', agentId: 'a1');
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
      final key = (convId: 'c1', agentId: 'a1');
      final notifier = container.read(chatProvider(key).notifier);
      await Future.delayed(const Duration(milliseconds: 50));

      notifier.incrementUnread();
      notifier.incrementUnread();

      notifier.decrementUnread(5);
      expect(container.read(chatProvider(key)).unreadCount, 0);
    });

    test('减到 0 时清 firstUnreadMessageId + showUnreadSeparator', () async {
      // override mock 让 _initialize 走「有未读」分支
      when(() => api.getUnreadInfo(any())).thenAnswer((_) async => {
            'unread_count': 2,
            'first_unread_message_id': 'm-unread-1',
            'first_unread_created_at': '2026-06-20T10:00:00Z',
            'has_more_before_first_unread': false,
          });
      when(() => api.getMessagesAfter(any(),
              after: any(named: 'after'), limit: any(named: 'limit')))
          .thenAnswer((_) async => [
                {
                  'id': 'm-unread-1',
                  'conversation_id': 'c1',
                  'sender_type': 'agent',
                  'sender_id': 'a1',
                  'content': {'msg_type': 'text', 'data': {'text': 'unread'}},
                  'created_at': '2026-06-20T10:00:00Z',
                },
              ]);

      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
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
}
