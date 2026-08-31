import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wanling_core/models/unread_info.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart'
    show apiProvider, authProvider, AuthNotifier, AuthState;
import 'package:wanling_core/providers/chat_provider.dart'
    show chatProvider, wsProvider;
import 'package:wanling_core/providers/local_message_store_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:app/providers/pending_attachment_provider.dart';
import 'package:app/widgets/chat/chat_input_bar.dart';
import 'package:app/widgets/chat/input_controller.dart';

import '../../helpers/fake_local_message_store.dart';
import '../../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;
  late FakeWS ws;
  late FakeLocalMessageStore store;

  const chatKey = (convId: 'conv-draft', agentId: 'a1');

  setUp(() {
    api = MockApi();
    ws = FakeWS();
    store = FakeLocalMessageStore();
    when(() => api.getUnreadInfo(any()))
        .thenAnswer((_) async => const UnreadInfo(unreadCount: 0));
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => <ChatMessage>[]);
    when(() => api.getMessages(any(),
            limit: any(named: 'limit'), offset: any(named: 'offset')))
        .thenAnswer((_) async => <ChatMessage>[]);
    // 点发送链路:InputController.send → ChatNotifier.sendText → api.sendMessage
    when(() => api.sendMessage(any(), any())).thenAnswer(
        (_) async =>
            (messageId: 'srv-1', createdAt: DateTime.parse('2026-01-01T00:00:00Z')));
  });

  Future<(ProviderContainer, Widget)> makeHarness({
    String? existingDraft,
  }) async {
    if (existingDraft != null) {
      await store.putDraft('u1', chatKey.convId, existingDraft);
    }
    final authNotifier = AuthNotifier(
      ApiService(baseUrl: 'http://test.local'),
    );
    authNotifier.state = AuthState(
      user: User(
        id: 'u1',
        username: 'alice',
        nickname: 'Alice',
        bio: '',
        createdAt: DateTime.parse('2026-01-01T00:00:00Z'),
      ),
      token: 't',
      isRestoring: false,
    );
    final container = ProviderContainer(overrides: [
      authProvider.overrideWith((ref) => authNotifier),
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
      localMessageStoreProvider.overrideWith((ref) async => store),
    ]);
    // 先等 store 就绪再锁定 chatProvider 实例:store loading→data 的
    // valueOrNull 变化会触发 chatProvider 重建,旧 ChatNotifier 会在
    // _initialize 飞行中被 dispose(Tried to use after dispose)。
    // 就绪后首建即拿到稳定 store,无中途重建。
    await container.read(localMessageStoreProvider.future);
    container.listen(chatProvider(chatKey), (_, _) {});
    // InputContext.ref 需要 WidgetRef(测试无 Widget 环境),按 brief fallback:
    // Consumer builder 内用真实 WidgetRef 构造 InputController。
    final widget = UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final inputController = InputController(InputContext(
                getContext: () => context,
                ref: ref,
                chatKey: chatKey,
                isMounted: () => true,
                getNotifier: () =>
                    container.read(chatProvider(chatKey).notifier),
              ));
              return ChatInputBar(
                inputController: inputController,
                chatKey: chatKey,
              );
            },
          ),
        ),
      ),
    );
    return (container, widget);
  }

  testWidgets('进入会话回填已存草稿', (tester) async {
    final (container, widget) = await makeHarness(existingDraft: '旧草稿文本');
    addTearDown(container.dispose);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
    expect(find.text('旧草稿文本'), findsOneWidget);
    // 回填会 echo 一次 onTextChanged → setText 重挂 500ms 防抖 timer,
    // 推进时钟让其 fire,防测试结束时 pending timer 报错(putDraft 同值幂等)。
    await tester.pump(const Duration(milliseconds: 600));
  });

  testWidgets('输入防抖后落库', (tester) async {
    final (container, widget) = await makeHarness();
    addTearDown(container.dispose);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新输入草稿');
    await tester.pump(const Duration(milliseconds: 600)); // 过防抖 500ms
    expect(await store.getDraft('u1', chatKey.convId), '新输入草稿');
  });

  testWidgets('点发送清草稿 + onSend 收到文本', (tester) async {
    final (container, widget) =
        await makeHarness(existingDraft: '待发送草稿');
    addTearDown(container.dispose);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '待发送草稿');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(await store.getDraft('u1', chatKey.convId), isNull);
    expect(
      container.read(pendingAttachmentProvider(chatKey)),
      isNull,
    );
  });
}
