import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
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

void main() {
  late _MockApi api;
  late FakeWS ws;

  setUp(() {
    api = _MockApi();
    ws = FakeWS();
    registerFallbackValue(<String, dynamic>{});
    // Host 弹窗时 convByIdProvider 查不到会话会 fire-and-forget 触发
    // conversationProvider.load()，stub 空列表避免未 stub 调用报错刷屏。
    when(() => api.getConversations()).thenAnswer((_) async => []);
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
}
