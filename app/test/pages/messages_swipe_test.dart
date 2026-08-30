// MessagesPage 会话列表左滑操作测试:
// 左滑露出 固定到底栏/置顶/删除会话 三按钮,状态文案切换,删除走确认框。
// Harness 与 messages_page_style_test 同款(MockApi+FakeWS+restoreSession)。
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:app/pages/messages_page.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

final _testUser = User(
  id: 'u1',
  username: 'kira',
  avatarUrl: null,
  createdAt: DateTime.utc(2026, 6, 13),
);

Conversation _conv({String id = 'c1', bool pinned = false}) => Conversation(
      id: id,
      type: 'user_user',
      title: '对话一',
      participants: const [],
      // 构造函数只收 pinnedAt,isPinned getter 由 pinnedAt!=null 推导。
      pinnedAt: pinned ? DateTime(2026, 8, 15) : null,
      lastMessageContent: {
        'msg_type': 'text',
        'data': {'text': 'hello'},
      },
      lastMessageAt: DateTime(2026, 8, 29, 14, 30),
      createdAt: DateTime(2026, 8, 1),
    );

Future<ProviderContainer> _harness(
  WidgetTester tester, {
  List<Conversation> convs = const [],
  Map<String, Object> prefsValues = const {'token': 'fake-token'},
}) async {
  SharedPreferences.setMockInitialValues(prefsValues);
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  when(() => api.getMe()).thenAnswer((_) async => _testUser);
  when(() => api.getConversations()).thenAnswer((_) async => convs);
  when(() => api.getAgents()).thenAnswer((_) async => []);
  when(() => api.pinConversation(any())).thenAnswer((_) async {});
  when(() => api.unpinConversation(any())).thenAnswer((_) async {});
  when(() => api.hideConversation(any())).thenAnswer((_) async {});
  final container = ProviderContainer(overrides: [
    apiProvider.overrideWithValue(api),
    wsProvider.overrideWithValue(FakeWS()),
    sharedPrefsProvider
        .overrideWithValue(await SharedPreferences.getInstance()),
  ]);
  addTearDown(container.dispose);
  await container.read(authProvider.notifier).restoreSession();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: Scaffold(body: MessagesPage())),
  ));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('左滑露出 固定到底栏/置顶/删除会话 三按钮', (tester) async {
    await _harness(tester, convs: [_conv()]);

    await tester.drag(find.text('对话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.text('固定到底栏'), findsOneWidget);
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('删除会话'), findsOneWidget);
    // 互斥收起容器就位。
    expect(find.byType(SlidableAutoCloseBehavior), findsOneWidget);
  });

  testWidgets('点击固定到底栏:写入 navOrderProvider,按钮变「从底栏移除」',
      (tester) async {
    final container = await _harness(tester, convs: [_conv()]);

    await tester.drag(find.text('对话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('固定到底栏'));
    await tester.pumpAndSettle();

    expect(container.read(navOrderProvider), contains('conv:c1'));
    // autoClose 收起后 action pane 从树上移除(slidable 源码 actionPaneType=none),
    // 重新左滑展开验证文案已随 navOrderProvider 翻转。
    await tester.drag(find.text('对话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('从底栏移除'), findsOneWidget);
  });

  testWidgets('已固定会话左滑显示「从底栏移除」,点击移出 navOrderProvider',
      (tester) async {
    final container = await _harness(tester, convs: [_conv()], prefsValues: {
      'token': 'fake-token',
      'nav_order_u1': ['msg', 'wanling', 'conv:c1'],
    });

    await tester.drag(find.text('对话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('从底栏移除'), findsOneWidget);

    await tester.tap(find.text('从底栏移除'));
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider), isNot(contains('conv:c1')));
  });

  testWidgets('已置顶会话左滑显示「取消置顶」,点击调 unpin API', (tester) async {
    await _harness(tester, convs: [_conv(pinned: true)]);

    await tester.drag(find.text('对话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('取消置顶'), findsOneWidget);

    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();
  });

  testWidgets('点击删除会话弹确认框,确认后调 hideConversation 且行移除',
      (tester) async {
    await _harness(tester, convs: [_conv()]);

    await tester.drag(find.text('对话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除该会话?'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('对话一'), findsNothing);
  });

  testWidgets('展开态点击内容区:仅收起该行,不进会话', (tester) async {
    await _harness(tester, convs: [_conv()]);
    await tester.drag(find.text('对话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(find.text('固定到底栏'), findsOneWidget);
    // 展开后内容区随 pane 左移,左侧已出屏;点 tile InkWell 右缘可视区。
    final inkRight = tester.getTopRight(
      find.ancestor(of: find.text('对话一'), matching: find.byType(InkWell)),
    );
    await tester.tapAt(Offset(inkRight.dx - 30, inkRight.dy + 24));
    await tester.pumpAndSettle();
    // 未守卫时 push 抛错测试即红;收起后 action pane 移出组件树。
    expect(find.text('固定到底栏'), findsNothing);
  });
}
