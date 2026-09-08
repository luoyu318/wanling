import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wanling_core/models/message.dart' show ChatMessage;
import 'package:wanling_core/models/unread_info.dart' show UnreadInfo;
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart'
    show ChatNotifier, wsProvider;
import 'package:wanling_core/rendering/builtin_renderers.dart'
    show registerBuiltinRenderers;
import 'package:wanling_core/rendering/card_renderer.dart'
    show CardContentRenderer;
import 'package:wanling_core/services/api_service.dart';

import 'package:app/providers/approval_inbox_provider.dart';
import 'package:app/widgets/inbox/approval_inbox_host.dart';

import '../helpers/fake_ws.dart';

class _MockApi extends Mock implements ApiService {}

WSMessage _createPerm(String id, String convId) => WSMessage(op: 0, d: {
      'id': id,
      'conversation_id': convId,
      'content': {
        'msg_type': 'permission_card',
        'data': {'status': 'pending', 'oc_request_id': 'oc1', 'action': 'bash'},
      },
    });

/// ④ approvals 卡消息（msg_type=card， hermes command 形态，含可点按钮）。
WSMessage _createApprovalCard(String id, String convId) =>
    WSMessage(op: 0, d: {
      'id': id,
      'conversation_id': convId,
      'content': {
        'msg_type': 'card',
        'data': {
          'card_type': 'command',
          'approval_id': 'ap-c1',
          'title': '执行命令',
          'preview': 'ls -la',
          'state': 'pending',
          'expires_at': DateTime.now()
              .add(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
          'actions': [
            {
              'id': 'allow_once',
              'label': '允许一次',
              'icon': 'check',
              'style': 'primary',
            },
            {
              'id': 'deny',
              'label': '拒绝',
              'icon': 'x',
              'style': 'danger',
            },
          ],
        },
      },
    });

void main() {
  late _MockApi api;
  late FakeWS ws;

  setUp(() {
    api = _MockApi();
    ws = FakeWS();
    registerFallbackValue(<String, dynamic>{});
    // static onDecide 是进程级状态，先清掉防用例间串扰（Host initState 会重装）。
    CardContentRenderer.onDecide = null;
    // ④ 卡经 ContentRendererRegistry 渲染，内置注册表需显式注册。
    registerBuiltinRenderers();
    // Host 弹窗时 convByIdProvider 查不到会话会 fire-and-forget 触发
    // conversationProvider.load()，stub 空列表避免未 stub 调用报错刷屏。
    when(() => api.getConversations()).thenAnswer((_) async => []);
    // ④ 卡弹窗渲染 MessageRenderContext 需要 baseUrl（非空 getter 必须 stub）。
    when(() => api.baseUrl).thenReturn('http://test.local');
  });

  ProviderContainer makeContainer() {
    return ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
  }

  testWidgets('队列非空且非当前会话 → 自动弹权限审批抽屉，含来源条与暂不处理',
      (tester) async {
    when(() => api.sendMessage(any(), any())).thenAnswer(
        (inv) async => (messageId: 'mid', createdAt: DateTime(2026)));
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ApprovalInboxHost(child: Scaffold())),
    ));
    // controller 随 Host 首帧构建即完成订阅，直接注入新卡。
    // FakeWS 是 broadcast 流异步投递，emit 后 pump 刷 microtask 才入队。
    ws.emit(_createPerm('m1', 'conv-9'));
    await tester.pump(); // 入队
    await tester.pump(const Duration(milliseconds: 350)); // 过 300ms 防抖
    await tester.pumpAndSettle(); // 抽屉进出场动画

    expect(find.text('权限审批'), findsOneWidget);
    expect(find.text('暂不处理'), findsOneWidget);
    expect(find.text('1 / 1'), findsOneWidget);
  });

  testWidgets('点暂不处理 → 抽屉关闭且不自动续弹', (tester) async {
    when(() => api.sendMessage(any(), any())).thenAnswer(
        (inv) async => (messageId: 'mid', createdAt: DateTime(2026)));
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ApprovalInboxHost(child: Scaffold())),
    ));
    ws.emit(_createPerm('m1', 'conv-9'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('权限审批'), findsOneWidget);

    await tester.tap(find.text('暂不处理'));
    await tester.pumpAndSettle();
    expect(find.text('权限审批'), findsNothing); // 抽屉已关
  });

  testWidgets('已提交决策（awaiting）的头条卡在收敛前不重弹', (tester) async {
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ApprovalInboxHost(child: Scaffold())),
    ));
    ws.emit(_createPerm('m1', 'conv-9'));
    await tester.pump(); // 入队
    // 模拟决策已提交：标记 awaiting（MESSAGE_UPDATE 尚未回流）。
    container.read(approvalInboxProvider.notifier).markAwaitingConfirm('m1');
    await tester.pump(const Duration(milliseconds: 350)); // 过防抖
    await tester.pumpAndSettle();

    expect(find.text('权限审批'), findsNothing); // awaiting 头条不弹
  });

  testWidgets('C1 哨兵：访问过聊天页（ChatNotifier 构造+dispose）后 ④ 卡决策仍打到 API',
      (tester) async {
    // ChatNotifier._initialize 异步尾巴的 stub（镜像 chat_provider_test setUp）。
    when(() => api.getUnreadInfo(any()))
        .thenAnswer((_) async => const UnreadInfo(unreadCount: 0));
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => <ChatMessage>[]);
    when(() => api.decideApproval(any(), any(),
            reason: any(named: 'reason'), answers: any(named: 'answers')))
        .thenAnswer((_) async => null);

    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ApprovalInboxHost(child: Scaffold())),
    ));

    // 模拟访问过聊天页：ChatNotifier 构造 → dispose。
    // 旧实现 dispose 把 static onDecide 置 null，④ 卡决策随后静默失效
    // （乐观翻转、零 API 调用、无收敛回流）。
    // 注意 widget 测试是 fake 时钟：等异步尾巴只能 pump，不能 Future.delayed。
    final notifier = ChatNotifier(api, ws, 'conv-c1', null, 'user-1');
    await tester.pump(const Duration(milliseconds: 50));
    notifier.dispose();

    // ④ approvals 卡入队 → 弹窗。
    ws.emit(_createApprovalCard('m1', 'conv-9'));
    await tester.pump(); // 入队
    await tester.pump(const Duration(milliseconds: 350)); // 过 300ms 防抖
    await tester.pump(); // 编排帧
    await tester.pump(const Duration(milliseconds: 400)); // 抽屉进出场

    expect(find.text('允许一次'), findsOneWidget);
    await tester.tap(find.text('允许一次'));
    await tester.pump(); // 决策回调微任务链
    await tester.pump(const Duration(milliseconds: 100));

    // 决策必须真实打到 API（旧实现 onDecide==null → 乐观翻转零调用）。
    verify(() => api.decideApproval('ap-c1', 'allow_once',
            reason: null, answers: null)).called(1);
    // Host 侧 awaiting 标记生效（防 MESSAGE_UPDATE 回流前重弹）。
    expect(container.read(approvalInboxProvider).awaitingKeys, contains('m1'));
  });

  testWidgets('I1 哨兵：被动关闭（pop 路由）等同暂不处理，exposing 恢复需新卡驱动',
      (tester) async {
    when(() => api.sendMessage(any(), any())).thenAnswer(
        (inv) async => (messageId: 'mid', createdAt: DateTime(2026)));
    final container = makeContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ApprovalInboxHost(child: Scaffold())),
    ));
    ws.emit(_createPerm('m1', 'conv-9'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('权限审批'), findsOneWidget);

    // 被动关闭：返回键/手势下滑/点遮罩在测试里等价于直接 pop 路由。
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();

    // 等同「暂不处理」（spec §6）：suppressed=true、exposing=false、卡片仍在队列。
    final state = container.read(approvalInboxProvider);
    expect(state.suppressed, isTrue);
    expect(state.exposing, isFalse);
    expect(state.queue.map((e) => e.entryKey), contains('m1'));

    // 新卡入队：exposing 恢复必须由新卡驱动（走 300ms 防抖），
    // 不能因旧状态泄漏（exposing 保持 true）立即重弹旧卡。
    ws.emit(_createPerm('m2', 'conv-8'));
    await tester.pump(); // 入队帧
    expect(container.read(approvalInboxProvider).exposing, isFalse);
    expect(find.text('权限审批'), findsNothing); // 防抖窗口内不重弹旧卡

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    // 队列保留语义（与「暂不处理」一致）：续弹重放队首 m1。
    expect(find.text('权限审批'), findsOneWidget);
  });
}
