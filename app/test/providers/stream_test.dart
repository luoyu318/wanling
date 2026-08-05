import 'dart:async';

import 'package:app/models/message.dart';
import 'package:app/models/unread_info.dart';
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
    // chatProvider 是 autoDispose.family:无 listener 时容器会在帧间隙回收实例。
    // 同 chat_provider_test.dart,建立长期 listener 锁定实例。
    container.listen(chatProvider((convId: 'c1', agentId: 'a1')), (_, __) {});
    return container;
  }

  /// 等 _initialize 异步尾巴跑完,避免与后续 emit 竞态。
  Future<void> pump([int ms = 50]) =>
      Future.delayed(Duration(milliseconds: ms));

  /// 通过 op=14 STREAM 流注入一块 delta(模拟 plugin 流式输出)。
  void emitStream(String streamId, String text,
      {String msgType = 'reasoning', String convId = 'c1'}) {
    ws.emitStream({
      'conversation_id': convId,
      'stream_id': streamId,
      'msg_type': msgType,
      'text': text,
    });
  }

  /// 通过 MESSAGE_CREATE 注入一条 agent 终态消息(可带 _stream_id 关联占位)。
  void emitAgentCreate(String id, String text,
      {String? streamId,
      String convId = 'c1',
      String msgType = 'text',
      String senderId = 'a1'}) {
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      d: {
        'id': id,
        'conversation_id': convId,
        'sender_type': 'agent',
        'sender_id': senderId,
        'content': {
          'msg_type': msgType,
          'data': {
            'text': text,
            if (streamId != null) '_stream_id': streamId,
          },
        },
        'created_at': '2026-07-24T00:00:00Z',
      },
    ));
  }

  /// 通过 MESSAGE_CREATE 注入聚合卡消息(msg_type=aggregate_card)。
  void emitAggregateCard(String id,
      {List<Map<String, dynamic>>? elements, String state = 'generating'}) {
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      d: {
        'id': id,
        'conversation_id': 'c1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'aggregate_card',
          'data': {'state': state, 'elements': elements ?? []},
        },
        'created_at': '2026-07-24T00:00:00Z',
      },
    ));
  }

  /// 通过 op=14 STREAM 注入聚合模式元素级流式帧(带 aggregate 定位字段)。
  void emitAggregateStream(String streamId, String text,
      {required String msgId,
      required String elementId,
      String msgType = 'markdown'}) {
    ws.emitStream({
      'conversation_id': 'c1',
      'stream_id': streamId,
      'msg_type': msgType,
      'text': text,
      'aggregate': {'message_id': msgId, 'element_id': elementId},
    });
  }

  group('live 插入顺序:新消息应在 busy 占位上方', () {
    test('思考中(isStreaming 占位)到达的卡片插到占位之前,不排在占位下方',
        () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      // agent 思考中:先有流式占位(恒在 live 底部)
      emitStream('s1', 'thinking', msgType: 'reasoning');
      await pump();

      // 思考中到达一张卡片(如 tool_call / permission_card)
      ws.emit(WSMessage(
        op: 0,
        t: 'MESSAGE_CREATE',
        d: {
          'id': 'card-1',
          'conversation_id': 'c1',
          'sender_type': 'agent',
          'sender_id': 'a1',
          'content': {
            'msg_type': 'tool_card',
            'data': {'title': '执行中'},
          },
          'created_at': '2026-07-24T00:01:00Z',
        },
      ));
      await pump();

      final live = container.read(chatProvider(key)).liveMessages;
      final cardIdx = live.indexWhere((m) => m.id == 'card-1');
      final streamIdx = live.indexWhere((m) => m.id == 'stream:s1');
      // 卡片必须在 busy 占位之前(上方),不得排到占位之后(下方)
      expect(cardIdx, isNot(-1));
      expect(streamIdx, isNot(-1));
      expect(cardIdx, lessThan(streamIdx));
    });

    test('无占位时新消息仍 append 末尾(保持原语义)', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      emitAgentCreate('a1', 'hi');
      await pump();
      emitAgentCreate('a2', 'world');
      await pump();

      final live = container.read(chatProvider(key)).liveMessages;
      expect(live.map((m) => m.id).toList(), ['a1', 'a2']);
    });
  });

  group('STREAM 流式占位', () {
    test('首块 delta → 插占位(id=stream:s1, isStreaming=true, agent)', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      emitStream('s1', 'Hel');
      await pump();

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      final ph = msgs.first;
      expect(ph.id, 'stream:s1');
      expect(ph.isStreaming, isTrue);
      expect(ph.senderType, 'agent');
      expect(ph.senderId, 'a1'); // 用会话 agentId
      expect(ph.content['msg_type'], 'reasoning');
      expect((ph.content['data'] as Map)['text'], 'Hel');
    });

    test('后续块 delta → 替换占位 text(累积全量),id 不变,不新增', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      emitStream('s1', 'Hel');
      await pump();
      emitStream('s1', 'Hello wor');
      await pump();

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1); // 只更新,不新增
      final ph = msgs.first;
      expect(ph.id, 'stream:s1'); // id 不变(同 stream_id)
      expect(ph.isStreaming, isTrue);
      expect((ph.content['data'] as Map)['text'], 'Hello wor');
    });

    test('STREAM 仅处理本会话事件(其他会话忽略)', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      emitStream('s1', 'x', convId: 'c2'); // 别的会话
      await pump();

      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });

    test('STREAM 携带非文本类 msg_type(step_finish)→ 不插占位(防御性过滤)',
        () async {
      // 协议边界:plugin 只对 reasoning/text 生成 streamId 推 sendStream,
      // step_finish 走独立 case 不经流式通道。此处验证防御性过滤兜底:
      // 即便未来 plugin 误发 step_finish STREAM,也不应插入无法被终态替换的占位。
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      emitStream('s1', 'unused', msgType: 'step_finish');
      await pump();

      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });
  });

  group('终态 MESSAGE_CREATE _stream_id 替换占位', () {
    test('带 _stream_id → 同位置替换占位,isStreaming 清除,_stream_id 字段清理',
        () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      // 先有占位
      emitStream('s1', 'Hello wor', msgType: 'reasoning');
      await pump();
      expect(container.read(chatProvider(key)).displayMessages.length, 1);
      expect(container.read(chatProvider(key)).displayMessages.first.id, 'stream:s1');

      // 终态到达(同 msg_type,带 _stream_id)
      emitAgentCreate('real-1', 'Hello world!',
          streamId: 's1', msgType: 'reasoning');
      await pump();

      final msgs = container.read(chatProvider(key)).displayMessages;
      // 占位移除
      expect(msgs.where((m) => m.id == 'stream:s1'), isEmpty);
      // 真实消息存在,isStreaming 清零
      expect(msgs.length, 1);
      final real = msgs.firstWhere((m) => m.id == 'real-1');
      expect(real.isStreaming, isFalse);
      // _stream_id 控制字段被清理(终态 content 不保留瞬态字段)
      final data = real.content['data'] as Map<String, dynamic>;
      expect(data.containsKey('_stream_id'), isFalse);
      expect(data['text'], 'Hello world!');
    });

    test('带 _stream_id 但占位不存在 → 正常头部插入(刚进会话未收到 STREAM)',
        () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      // 无前置 STREAM,直接终态带 _stream_id
      emitAgentCreate('real-2', 'late', streamId: 's2');
      await pump();

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      expect(msgs.first.id, 'real-2');
      // 控制字段仍清理(终态 content 不保留瞬态字段,无论占位是否存在)
      final data = msgs.first.content['data'] as Map<String, dynamic>;
      expect(data.containsKey('_stream_id'), isFalse);
    });

    test('不带 _stream_id → 正常头部插入(向后兼容)', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      emitAgentCreate('plain-1', '普通终态');
      await pump();

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      expect(msgs.first.id, 'plain-1');
      expect(msgs.first.isStreaming, isFalse);
    });
  });

  test('_initialize 拉历史时清除残留 isStreaming 占位(竞态兜底)', () async {
    // 用 Completer 挂起 getUnreadInfo,模拟 _initialize 异步窗口:
    // 窗口内 STREAM 到达插占位 → server 历史返回后 _mergeHistory 必须把
    // isStreaming 占位从 extra 排除(历史是真相源,只含终态)。
    final unreadCompleter = Completer<UnreadInfo>();
    when(() => api.getUnreadInfo(any()))
        .thenAnswer((_) => unreadCompleter.future);
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => [
              ChatMessage(
                id: 'real-1',
                conversationId: 'c1',
                senderType: 'agent',
                senderId: 'a1',
                content: const {
                  'msg_type': 'text',
                  'data': {'text': 'done'}
                },
                createdAt: DateTime.parse('2026-07-24T00:00:00Z'),
              ),
            ]);

    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    container.read(chatProvider(key).notifier);
    await pump(20); // 让 _initialize 跑到 await getUnreadInfo 挂起

    // 竞态窗口:_initialize 还在等 server,STREAM 到达 → 插占位
    emitStream('s1', 'streaming...');
    await pump(20);
    final during = container.read(chatProvider(key)).displayMessages;
    expect(during.any((m) => m.id == 'stream:s1' && m.isStreaming), isTrue);

    // 释放 _initialize:getUnreadInfo 返回 → getMessagesBefore 返回 real-1
    // → _mergeHistory 运行,extra 必须排除 isStreaming 占位
    unreadCompleter.complete(const UnreadInfo(unreadCount: 0));
    await pump();

    final after = container.read(chatProvider(key)).displayMessages;
    expect(after.any((m) => m.isStreaming), isFalse);
    expect(after.where((m) => m.id == 'stream:s1'), isEmpty);
    expect(after.any((m) => m.id == 'real-1'), isTrue);
  });

  test('_initialize 完成后 isServerInitialized=true(底部栏稳定信号)', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    container.read(chatProvider(key).notifier);
    await pump();
    // server 三分支任一完成即置 true,pendingInitialScroll 据此判断
    // 底部输入区(convType/sessionMeta)已稳定,避免过早 jumpTo 被 strip 遮挡
    expect(container.read(chatProvider(key)).isServerInitialized, isTrue);
  });

  group('聚合卡 op=14 元素级流式(带 aggregate 字段)', () {
    test('带 aggregate 的 delta 更新聚合卡元素 data.text,不建独立占位', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      // 先有聚合卡消息(plugin ensureCard 建的 MESSAGE_CREATE)
      emitAggregateCard('agg-1', elements: [
        {
          'type': 'markdown',
          'element_id': 'markdown_1',
          'data': {'text': 'Hi'},
        },
      ]);
      await pump();

      // 元素级流式:更新 markdown_1 的 text(全量替换)
      emitAggregateStream('s1', 'Hello world',
          msgId: 'agg-1', elementId: 'markdown_1');
      await pump();

      final msgs = container.read(chatProvider(key)).displayMessages;
      // 只更新卡片,不新增独立占位
      expect(msgs.length, 1);
      expect(msgs.first.id, 'agg-1');
      expect(msgs.where((m) => m.id == 'stream:s1'), isEmpty);
      final elements =
          (msgs.first.content['data'] as Map)['elements'] as List;
      final element = elements.first as Map;
      expect(element['element_id'], 'markdown_1');
      expect((element['data'] as Map)['text'], 'Hello world');
    });

    test('多元素卡片仅更新 element_id 匹配的元素,其余保持不变', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      emitAggregateCard('agg-1', elements: [
        {
          'type': 'reasoning',
          'element_id': 'reasoning_1',
          'data': {'text': '思考中'},
        },
        {
          'type': 'markdown',
          'element_id': 'markdown_1',
          'data': {'text': '正文'},
        },
      ]);
      await pump();

      emitAggregateStream('s1', '更新后的正文',
          msgId: 'agg-1', elementId: 'markdown_1');
      await pump();

      final msgs = container.read(chatProvider(key)).displayMessages;
      final elements =
          ((msgs.first.content['data'] as Map)['elements'] as List)
              .cast<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
      expect(elements.length, 2);
      expect((elements[0]['data'] as Map)['text'], '思考中'); // reasoning 未动
      expect((elements[1]['data'] as Map)['text'], '更新后的正文');
    });

    test('aggregate 帧找不到聚合卡 → 不建占位(静默丢弃,等待 MESSAGE_UPDATE 兜底)',
        () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      // 流式帧早于建卡 MESSAGE_CREATE 到达
      emitAggregateStream('s1', 'x', msgId: 'ghost', elementId: 'markdown_1');
      await pump();

      expect(container.read(chatProvider(key)).displayMessages, isEmpty);
    });

    test('aggregate 帧 element_id 不匹配 → 卡片不动,不建占位', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      emitAggregateCard('agg-1', elements: [
        {
          'type': 'markdown',
          'element_id': 'markdown_1',
          'data': {'text': '原文'},
        },
      ]);
      await pump();

      emitAggregateStream('s1', '新文本',
          msgId: 'agg-1', elementId: 'markdown_2');
      await pump();

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      final elements =
          ((msgs.first.content['data'] as Map)['elements'] as List);
      final element = elements.first as Map;
      expect((element['data'] as Map)['text'], '原文'); // 未匹配,保持不变
    });

    test('非聚合模式(无 aggregate 字段)仍走旧占位逻辑', () async {
      final container = makeContainer();
      final key = (convId: 'c1', agentId: 'a1');
      container.read(chatProvider(key).notifier);
      await pump();

      emitStream('s1', 'Hel');
      await pump();

      final msgs = container.read(chatProvider(key)).displayMessages;
      expect(msgs.length, 1);
      expect(msgs.first.id, 'stream:s1');
      expect(msgs.first.isStreaming, isTrue);
    });
  });
}
