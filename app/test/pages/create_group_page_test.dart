import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/user_summary.dart';
import 'package:app/pages/create_group_page.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/friend_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_ws.dart';

/// 测试用 MockApi(参考 providers/conversation_provider_test.dart 模式)。
class MockApi extends Mock implements ApiService {}

Widget _wrapWithRouter(ProviderContainer container) {
  // GoRouter 必须 initialLocation + 把目标页注册在 '/',否则 pump 不出来
  // (参考 login_page_test.dart 模式)。
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const CreateGroupPage()),
      GoRoute(
          path: '/friends/add', builder: (_, _) => const SizedBox.shrink()),
      GoRoute(
          path: '/chat/:convId', builder: (_, _) => const SizedBox.shrink()),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  late MockApi api;
  late FakeWS ws;

  setUp(() {
    api = MockApi();
    ws = FakeWS();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// 注册 createGroup 触发 autoload 链路所需的兜底 mock。
  /// conversationProvider 构造时调 load() → getConversations,本测试只关心
  /// createConversation,故 getConversations 返空避免 Null 类型错误。
  void stubAutoloadDeps() {
    when(() => api.getConversations()).thenAnswer((_) async => []);
  }

  testWidgets('选中 ≥2 好友后点创建,触发 createGroup(memberUsernames)',
      (tester) async {
    when(() => api.listFriends()).thenAnswer((_) async => [
          UserSummary(username: 'alice', nickname: 'Alice', avatarUrl: ''),
          UserSummary(username: 'bob', nickname: 'Bob', avatarUrl: ''),
          UserSummary(username: 'carol', nickname: 'Carol', avatarUrl: ''),
        ]);
    when(() => api.listIncomingFriendRequests()).thenAnswer((_) async => []);
    when(() => api.listOutgoingFriendRequests()).thenAnswer((_) async => []);
    stubAutoloadDeps();

    // mock createConversation 返新建会话(last_message_at 必填,否则 fromJson 崩)
    when(() => api.createConversation(
          type: any(named: 'type'),
          memberIds: any(named: 'memberIds'),
          memberTypes: any(named: 'memberTypes'),
          memberUsernames: any(named: 'memberUsernames'),
          title: any(named: 'title'),
          avatarUrl: any(named: 'avatarUrl'),
        )).thenAnswer((_) async => Conversation(
              id: 'new-conv',
              type: 'group_user',
              title: 'test group',
              avatarUrl: null,
              agent: null,
              otherUser: null,
              participants: const [],
              lastMessageContent: null,
              lastMessageAt: DateTime.utc(2026, 7, 3),
              createdAt: DateTime.utc(2026, 7, 3),
              unreadCount: 0,
            ));

    final container = makeContainer();
    // 预热 friendListProvider(autoload=true 构造即拉,显式 await load 兜底)
    await container.read(friendListProvider.notifier).load();

    await tester.pumpWidget(_wrapWithRouter(container));
    await tester.pumpAndSettle();

    // 输群名(找第一个 TextField = 群名输入框)
    await tester.enterText(find.byType(TextField).first, 'test group');

    // 勾选 Alice 和 Bob(CheckboxListTile 的 title 文本)
    await tester.tap(find.text('Alice'));
    await tester.pump();
    await tester.tap(find.text('Bob'));
    await tester.pump();

    // 点创建按钮
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    // 校验 createConversation 被调用,memberUsernames 含 alice + bob
    final captured = verify(() => api.createConversation(
          type: captureAny(named: 'type'),
          memberIds: captureAny(named: 'memberIds'),
          memberTypes: captureAny(named: 'memberTypes'),
          memberUsernames: captureAny(named: 'memberUsernames'),
          title: captureAny(named: 'title'),
          avatarUrl: captureAny(named: 'avatarUrl'),
        )).captured;

    expect(captured[0], 'group_user');
    expect(captured[1], <String>[]); // memberIds 必须为空
    expect(captured[2], <String>[]); // memberTypes 必须为空
    expect((captured[3] as List).length, 2);
    expect(captured[3], containsAll(['alice', 'bob']));
    expect(captured[4], 'test group');
  });

  testWidgets('无好友时显示空态引导', (tester) async {
    when(() => api.listFriends()).thenAnswer((_) async => []);
    when(() => api.listIncomingFriendRequests()).thenAnswer((_) async => []);
    when(() => api.listOutgoingFriendRequests()).thenAnswer((_) async => []);

    final container = makeContainer();
    await container.read(friendListProvider.notifier).load();

    await tester.pumpWidget(_wrapWithRouter(container));
    await tester.pumpAndSettle();

    expect(find.text('还没有好友'), findsOneWidget);
    expect(find.text('去添加好友'), findsOneWidget);
  });

  testWidgets('Conversation.fromJson 解析 group_user 不崩', (tester) async {
    // 校验 server 返回结构可正常解析,避免 mock 数据 schema 漂移。
    final conv = Conversation.fromJson({
      'id': 'g1',
      'type': 'group_user',
      'title': '群名',
      'avatar_url': null,
      'participants': <Map<String, dynamic>>[],
      'last_message_content': null,
      'last_message_at': DateTime.utc(2026, 7, 3).toIso8601String(),
      'created_at': DateTime.utc(2026, 7, 3).toIso8601String(),
      'unread_count': 0,
    });
    expect(conv.id, 'g1');
    expect(conv.title, '群名');
  });
}
