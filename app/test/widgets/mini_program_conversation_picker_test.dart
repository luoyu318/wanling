// 会话选择器 widget 测试:宫格渲染/点击回传 convId/空态/遮罩取消返 null。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:app/widgets/mini_program_conversation_picker.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

Conversation _conv(String id, String title) => Conversation(
      id: id,
      type: 'group',
      title: title,
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime(2026),
      createdAt: DateTime(2026),
    );

/// 覆盖 conversationProvider(autoload:false + 直接赋 state,仿 nav_order_test,
/// NoopLocalMessageStore 绕开 store 依赖),pump 出 share 按钮交给 onShare。
Future<void> _pump(
  WidgetTester tester,
  List<Conversation> convs,
  void Function(BuildContext, WidgetRef) onShare,
) async {
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  final container = ProviderContainer(overrides: [
    conversationProvider.overrideWith((ref) => ConversationListNotifier(
        api, FakeWS(), 'u1', NoopLocalMessageStore(),
        autoload: false)),
  ]);
  addTearDown(container.dispose);
  container.read(conversationProvider.notifier).state = convs;

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Center(
          child: Consumer(
            builder: (ctx, ref, _) => ElevatedButton(
              onPressed: () => onShare(ctx, ref),
              child: const Text('share'),
            ),
          ),
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('宫格渲染会话名称且点击返回 convId', (tester) async {
    final pickedFuture = Completer<String?>();
    await _pump(tester, [_conv('c1', '测试群'), _conv('c2', '第二群')],
        (ctx, ref) async {
      final picked =
          await showMiniProgramConversationPicker(context: ctx, ref: ref);
      pickedFuture.complete(picked);
    });
    await tester.tap(find.text('share'));
    await tester.pumpAndSettle();

    expect(find.text('分享到'), findsOneWidget);
    expect(find.text('测试群'), findsOneWidget);
    expect(find.text('第二群'), findsOneWidget);

    await tester.tap(find.text('测试群'));
    await tester.pumpAndSettle();
    expect(await pickedFuture.future, 'c1');
  });

  testWidgets('空会话列表渲染「暂无会话」,遮罩取消返 null', (tester) async {
    Future<String?>? picked;
    await _pump(tester, const [], (ctx, ref) {
      picked = showMiniProgramConversationPicker(context: ctx, ref: ref);
    });
    await tester.tap(find.text('share'));
    await tester.pumpAndSettle();
    expect(find.text('暂无会话'), findsOneWidget);
    // 点遮罩(默认 surface 800x600,sheet 从底部弹出,顶部为 barrier)关闭
    await tester.tapAt(const Offset(400, 10));
    await tester.pumpAndSettle();
    expect(await picked, isNull);
  });
}
