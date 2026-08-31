// 会话选择器 widget 测试:列出会话点击返回 convId / 空列表空态返回 null。
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
      type: 'group_user',
      title: title,
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime(2026, 8, 1),
      createdAt: DateTime(2026, 8, 1),
    );

/// 覆盖 conversationProvider(autoload:false + 直接赋 state,仿 nav_order_test)
/// 并 pump 触发按钮,返回捕获的 picker Future。
Future<Future<String?>?> _pumpPicker(
  WidgetTester tester,
  List<Conversation> convs,
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

  Future<String?>? picked;
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Consumer(
        builder: (context, ref, _) => Scaffold(
          body: ElevatedButton(
            onPressed: () => picked =
                showMiniProgramConversationPicker(context: context, ref: ref),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return picked;
}

void main() {
  testWidgets('列出会话,点击返回 convId', (tester) async {
    final picked = await _pumpPicker(tester, [
      _conv('c1', '测试群'),
      _conv('c2', '开发小队'),
    ]);
    expect(find.text('测试群'), findsOneWidget);
    expect(find.text('开发小队'), findsOneWidget);
    await tester.tap(find.text('测试群'));
    await tester.pumpAndSettle();
    expect(await picked, 'c1');
  });

  testWidgets('空会话列表显示空态,返回 null', (tester) async {
    final picked = await _pumpPicker(tester, []);
    expect(find.text('暂无会话'), findsOneWidget);
    // 点遮罩(默认 surface 800x600,sheet 从底部弹出,顶部为 barrier)关闭
    await tester.tapAt(const Offset(400, 10));
    await tester.pumpAndSettle();
    expect(await picked, isNull);
  });
}
