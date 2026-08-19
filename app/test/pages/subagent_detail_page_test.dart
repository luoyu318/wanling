// subagent_detail_page_test.dart
//
// 验证子 Agent 详情页：
//   - 空状态：API 返空列表时显示「暂无子 Agent 内容」
//   - 加载态：拉取期间显示 CircularProgressIndicator
//   - 渲染态：API 返多条消息时按 root_msg_id 渲染子事件
//   - WS 增量：监听 ws.messages，root_msg_id 匹配的消息追加显示
//
// 策略：widget test，stub apiProvider.getSubagentMessages，直接 pump
// SubagentDetailPage；WS 用 FakeWS 注入。
import 'dart:async';

import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:app/pages/subagent_detail_page.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart' show wsProvider;
import 'package:app/rendering/builtin_renderers.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:app/widgets/chat/jump_to_bottom_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

ChatMessage _mkMsg({
  required String id,
  String msgType = 'text',
  Map<String, dynamic> data = const {},
}) {
  return ChatMessage(
    id: id,
    conversationId: 'conv-1',
    senderType: 'agent',
    senderId: 'agent-1',
    content: {
      'msg_type': msgType,
      'data': data,
    },
    createdAt: DateTime.parse('2026-07-13T10:00:00Z'),
  );
}

void main() {
  late MockApi api;
  late FakeWS ws;

  setUpAll(() {
    registerBuiltinRenderers();
  });

  setUp(() {
    api = MockApi();
    // mocktail 未 stub 的非空 String getter 返 null 触发 type error,补 baseUrl stub。
    when(() => api.baseUrl).thenReturn('http://test.local');
    ws = FakeWS();
  });

  Widget buildApp(ProviderContainer container, {String title = ''}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: SubagentDetailPage(
          taskCardId: 'root-1',
          convId: 'conv-1',
          title: title,
        ),
      ),
    );
  }

  testWidgets('空状态显示「暂无子 Agent 内容」', (tester) async {
    when(() => api.getSubagentMessages('conv-1', 'root-1'))
        .thenAnswer((_) async => []);

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    // 先一帧让 initState 触发 _loadMessages 的 Future 进入 flight
    await tester.pump();
    // 等 Future 完成
    await tester.pumpAndSettle();

    expect(find.text('暂无子 Agent 内容'), findsOneWidget);
    expect(find.text('子 Agent 详情'), findsOneWidget);
  });

  testWidgets('加载中显示 CircularProgressIndicator', (tester) async {
    // 永不完成的 Future，让加载态保持
    when(() => api.getSubagentMessages('conv-1', 'root-1'))
        .thenAnswer((_) => Completer<List<ChatMessage>>().future);

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('加载失败显示错误视图 + 重试', (tester) async {
    when(() => api.getSubagentMessages('conv-1', 'root-1'))
        .thenThrow(Exception('network down'));

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('有消息时渲染子事件列表', (tester) async {
    final msgs = [
      _mkMsg(id: 'm1', msgType: 'text', data: {'text': '子 agent 说'}),
      _mkMsg(id: 'm2', msgType: 'text', data: {'text': 'tool 调用结果'}),
    ];
    when(() => api.getSubagentMessages('conv-1', 'root-1'))
        .thenAnswer((_) async => msgs);

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    expect(find.text('子 agent 说'), findsOneWidget);
    expect(find.text('tool 调用结果'), findsOneWidget);
    expect(find.text('暂无子 Agent 内容'), findsNothing);
  });

  testWidgets('step_finish(Token 用量行)不渲染', (tester) async {
    // step_finish 无论 finished 与否都是 Token 用量/耗时元信息，app 不展示。
    // 混在正常 text 之间返回，验证两类都不渲染、text 正常渲染。
    final msgs = [
      _mkMsg(id: 't1', msgType: 'text', data: {'text': '前一条'}),
      _mkMsg(
        id: 'sf1',
        msgType: 'step_finish',
        data: {
          'tokens': {'total': 5000},
          'finished': true,
        },
      ),
      _mkMsg(
        id: 'sf2',
        msgType: 'step_finish',
        data: {
          'duration': 3.2,
          'tokens': {'total': 1200},
          'cost': 0.012,
        },
      ),
      _mkMsg(id: 't2', msgType: 'text', data: {'text': '后一条'}),
    ];
    when(() => api.getSubagentMessages('conv-1', 'root-1'))
        .thenAnswer((_) async => msgs);

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    // 正常 text 渲染
    expect(find.text('前一条'), findsOneWidget);
    expect(find.text('后一条'), findsOneWidget);
    // step_finish 的 Token 用量文案不出现
    expect(find.textContaining('tokens'), findsNothing);
  });

  testWidgets('WS 推送 root_msg_id 匹配的消息实时追加', (tester) async {
    when(() => api.getSubagentMessages('conv-1', 'root-1'))
        .thenAnswer((_) async => []);

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    // 初始空状态
    expect(find.text('暂无子 Agent 内容'), findsOneWidget);

    // 模拟 WS 推送一条本 root 下的子事件
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      d: {
        'id': 'ws-1',
        'conversation_id': 'conv-1',
        'sender_type': 'agent',
        'sender_id': 'agent-1',
        'content': {
          'msg_type': 'text',
          'data': {'text': '实时事件'},
        },
        'root_msg_id': 'root-1',
        'created_at': '2026-07-13T10:01:00Z',
      },
    ));
    await tester.pumpAndSettle();

    expect(find.text('实时事件'), findsOneWidget);
    expect(find.text('暂无子 Agent 内容'), findsNothing);
  });

  testWidgets('WS 推送非本 root 的消息不追加', (tester) async {
    when(() => api.getSubagentMessages('conv-1', 'root-1'))
        .thenAnswer((_) async => []);

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    // 推送 root_msg_id 不匹配的消息（属于其他 task 卡片）
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      d: {
        'id': 'ws-other',
        'conversation_id': 'conv-1',
        'sender_type': 'agent',
        'sender_id': 'agent-1',
        'content': {
          'msg_type': 'text',
          'data': {'text': '其他 root 的事件'},
        },
        'root_msg_id': 'other-root',
        'created_at': '2026-07-13T10:01:00Z',
      },
    ));
    await tester.pumpAndSettle();

    // 仍空状态，未误收
    expect(find.text('暂无子 Agent 内容'), findsOneWidget);
    expect(find.text('其他 root 的事件'), findsNothing);
  });

  testWidgets('I-G: WS MESSAGE_UPDATE 按 message_id 替换条目 content(task 终态同步)',
      (tester) async {
    // 初始 API 返一条 task 卡片(status=completed 无动画,避免 pumpAndSettle 卡死),
    // 详情页打开期间 server 推 MESSAGE_UPDATE 把同 msgId 的 output 改写,
    // 详情页应实时刷新出新文案。
    final initialTask = _mkMsg(
      id: 'task-msg-1',
      msgType: 'tool_card',
      data: <String, dynamic>{
        'name': 'task',
        'input': <String, dynamic>{'description': '测试任务'},
        'output': '旧结果',
        'status': 'completed',
        'sub_session_id': 'sess-child-1',
        'duration': 1.0,
      },
    );
    when(() => api.getSubagentMessages('conv-1', 'root-1'))
        .thenAnswer((_) async => [initialTask]);

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    // 初始渲染:旧结果文案出现
    expect(find.textContaining('旧结果'), findsNothing,
        reason: 'completed 状态的 output 不直接渲染在卡面上,改观察 duration');
    expect(find.textContaining('1.0s'), findsOneWidget);

    // 推 MESSAGE_UPDATE:同 message_id,新 content 把 duration/output 改写。
    // 用 emitUpdate 走 messageUpdates 流(对应 ws.messageUpdates 订阅),
    // payload 字段对齐 server dispatch.go BroadcastMessageUpdate:
    // 只含 message_id + conversation_id + content(不带 id/sender_*)。
    ws.emitUpdate(WSMessage(
      op: 0,
      t: 'MESSAGE_UPDATE',
      d: <String, dynamic>{
        'message_id': 'task-msg-1',
        'conversation_id': 'conv-1',
        'content': <String, dynamic>{
          'msg_type': 'tool_card',
          'data': <String, dynamic>{
            'name': 'task',
            'input': <String, dynamic>{'description': '测试任务'},
            'output': '新结果',
            'status': 'completed',
            'sub_session_id': 'sess-child-1',
            'duration': 2.5,
          },
        },
      },
    ));
    await tester.pumpAndSettle();

    // 验证:duration 切到 2.5s(说明 content 已替换)
    expect(find.textContaining('2.5s'), findsOneWidget);
    expect(find.textContaining('1.0s'), findsNothing);
  });

  testWidgets('I-G: WS MESSAGE_UPDATE 非本 root 子树的消息不替换', (tester) async {
    final initialTask = _mkMsg(
      id: 'task-msg-1',
      msgType: 'tool_card',
      data: <String, dynamic>{
        'name': 'task',
        'input': <String, dynamic>{},
        'output': '本子树结果',
        'status': 'completed',
        'duration': 1.0,
      },
    );
    when(() => api.getSubagentMessages('conv-1', 'root-1'))
        .thenAnswer((_) async => [initialTask]);

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    // 推 message_id 不匹配本子树的 UPDATE,应被忽略
    ws.emitUpdate(WSMessage(
      op: 0,
      t: 'MESSAGE_UPDATE',
      d: <String, dynamic>{
        'message_id': 'other-msg-not-in-tree',
        'conversation_id': 'conv-1',
        'content': <String, dynamic>{
          'msg_type': 'tool_card',
          'data': <String, dynamic>{
            'name': 'task',
            'output': '别家的',
            'status': 'completed',
            'duration': 9.9,
          },
        },
      },
    ));
    await tester.pumpAndSettle();

    // 验证:未替换,duration 仍是 1.0s(没切到 9.9s)
    expect(find.textContaining('1.0s'), findsOneWidget);
    expect(find.textContaining('9.9s'), findsNothing);
  });

  group('AppBar 标题', () {
    testWidgets('title 非空显示任务名称', (tester) async {
      when(() => api.getSubagentMessages('conv-1', 'root-1'))
          .thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(buildApp(container, title: '审查登录模块'));
      await tester.pumpAndSettle();

      expect(find.text('审查登录模块'), findsOneWidget);
      expect(find.text('子 Agent 详情'), findsNothing);
    });

    testWidgets('title 空串退化默认标题', (tester) async {
      when(() => api.getSubagentMessages('conv-1', 'root-1'))
          .thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(buildApp(container));
      await tester.pumpAndSettle();

      expect(find.text('子 Agent 详情'), findsOneWidget);
    });
  });

  group('跳转到底部浮标', () {
    testWidgets('消息少时(在底部)不显示浮标', (tester) async {
      final msgs = [
        _mkMsg(id: 'm1', msgType: 'text', data: {'text': '一条消息'}),
      ];
      when(() => api.getSubagentMessages('conv-1', 'root-1'))
          .thenAnswer((_) async => msgs);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(buildApp(container));
      await tester.pumpAndSettle();

      expect(find.byType(JumpToBottomButton), findsNothing);
    });

    testWidgets('上滑后显示浮标', (tester) async {
      final msgs = List.generate(
        30,
        (i) => _mkMsg(
          id: 'm$i',
          msgType: 'text',
          data: {'text': '消息 $i'},
        ),
      );
      when(() => api.getSubagentMessages('conv-1', 'root-1'))
          .thenAnswer((_) async => msgs);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
      ]);
      addTearDown(container.dispose);

      await tester.pumpWidget(buildApp(container));
      await tester.pumpAndSettle();

      // 初始在底部,浮标不显示
      expect(find.byType(JumpToBottomButton), findsNothing);

      // 上滑离开底部
      await tester.drag(
        find.byType(ListView),
        const Offset(0, 300),
      );
      await tester.pumpAndSettle();

      expect(find.byType(JumpToBottomButton), findsOneWidget);
    });
  });
}
