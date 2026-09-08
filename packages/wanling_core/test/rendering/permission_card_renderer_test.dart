import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/rendering/permission_card_renderer.dart';
import 'package:wanling_core/rendering/question_card_renderer.dart';
import 'package:wanling_core/services/api_service.dart';

/// 手写 fake：本包无 mocktail 依赖，override sendMessage 计数即可。
class _FakeApi extends ApiService {
  int sendMessageCalls = 0;

  _FakeApi() : super(baseUrl: 'http://test.local');

  @override
  Future<({String messageId, DateTime createdAt})> sendMessage(
    String conversationId,
    Map<String, dynamic> content,
  ) async {
    sendMessageCalls++;
    return (messageId: 'mid', createdAt: DateTime(2026));
  }
}

void main() {
  late _FakeApi api;

  setUp(() {
    api = _FakeApi();
  });

  Widget host(WidgetBuilder builder, ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Builder(builder: builder)),
    );
  }

  testWidgets('showQuestionReplySheet 传入 header 渲染在把手下方，提交成功触发 onSettled',
      (tester) async {
    final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    var settled = false;

    await tester.pumpWidget(host((ctx) {
      return Column(children: [
        TextButton(
          onPressed: () => showQuestionReplySheet(
            ctx,
            convId: 'c1',
            ocRequestId: 'oc1',
            questions: const [
              {'question': '选一个', 'header': 'Q1', 'options': [
                {'label': 'A'}, {'label': 'B'},
              ]},
            ],
            header: const Text('INBOX_SOURCE_HEADER'),
            onSettled: () => settled = true,
          ),
          child: const Text('open'),
        ),
      ]);
    }, container));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('INBOX_SOURCE_HEADER'), findsOneWidget);
    expect(find.text('选择题'), findsOneWidget);

    await tester.tap(find.text('A')); // 选中选项
    await tester.pump();
    await tester.tap(find.text('提交回答'));
    await tester.pumpAndSettle();

    expect(settled, isTrue);
    expect(api.sendMessageCalls, 1);
  });

  testWidgets('showPermissionReplySheet header 为 null 时行为不变，确认成功触发 onSettled',
      (tester) async {
    final container = ProviderContainer(
        overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(container.dispose);
    var settled = false;

    await tester.pumpWidget(host((ctx) {
      return Column(children: [
        TextButton(
          onPressed: () => showPermissionReplySheet(
            ctx,
            convId: 'c1',
            ocRequestId: 'oc1',
            action: 'bash',
            resources: const [],
            metadata: const {'command': 'ls'},
            save: const [],
            onSettled: () => settled = true,
          ),
          child: const Text('open'),
        ),
      ]);
    }, container));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('权限审批'), findsOneWidget); // 原头部仍在
    expect(find.text('INBOX_SOURCE_HEADER'), findsNothing);

    await tester.tap(find.text('仅本次允许'));
    await tester.pump();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(settled, isTrue);
  });
}
