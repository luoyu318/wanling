// MessagesPage 样式对齐 mockup 回归测试:
// 名字 15/w400、预览 12/w400、时间 11/w400 #999999、头像 radius 13 + tinted、无分割线。
// Harness 与 e2e 同款(MockApi+FakeWS+restoreSession),会话 fixture 走 getConversations。
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:app/pages/messages_page.dart';
import 'package:app/widgets/avatar.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderConstrainedBox;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

Conversation _conv() => Conversation(
      id: 'c1',
      type: 'user_user',
      title: '对话一',
      participants: const [],
      lastMessageContent: {
        'msg_type': 'text',
        'data': {'text': 'hello'},
      },
      lastMessageAt: DateTime(2026, 8, 29, 14, 30),
      createdAt: DateTime(2026, 8, 1),
    );

/// 复刻 _ConvTile._formatTime 的输出(今天 HH:mm / 非今天 M-d 无前导零)。
/// 时间断言文本随执行日动态计算,fixture 日期不锁死测试寿命。
String _expectedTimeText(DateTime t) {
  final local = t.toLocal();
  final now = DateTime.now();
  if (local.year == now.year &&
      local.month == now.month &&
      local.day == now.day) {
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
  return '${local.month}-${local.day}';
}

Future<ProviderContainer> _harness(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'token': 'fake-token'});
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  when(() => api.getMe()).thenAnswer((_) async => _testUser);
  when(() => api.getConversations()).thenAnswer((_) async => [_conv()]);
  when(() => api.getAgents()).thenAnswer((_) async => []);
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
    // MessagesPage 生产挂在 HomePage 的 Scaffold 里,InkWell 需要 Material 祖先,
    // 测试里用 Scaffold 包一层(同 messages_page_route_test)。
    child: const MaterialApp(home: Scaffold(body: MessagesPage())),
  ));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('名字 15/w400,预览 12/w400,时间 11/w400 #999999', (tester) async {
    await _harness(tester);

    final title = tester.widget<Text>(find.text('对话一'));
    expect(title.style?.fontSize, 15);
    expect(title.style?.fontWeight, FontWeight.w400);

    final preview = tester.widget<Text>(find.text('hello'));
    expect(preview.style?.fontSize, 12);
    expect(preview.style?.fontWeight, FontWeight.w400);

    final time = tester
        .widget<Text>(find.text(_expectedTimeText(_conv().lastMessageAt)));
    expect(time.style?.fontSize, 11);
    expect(time.style?.fontWeight, FontWeight.w400);
    expect(time.style?.color, const Color(0xFF999999));
  });

  testWidgets('头像 radius 13,分割线不存在', (tester) async {
    await _harness(tester);

    final avatar = tester.widget<Avatar>(find.byType(Avatar));
    expect(avatar.radius, 13);
    expect(avatar.tinted, isTrue);

    // 0.5px 分割线 Container(height:0.5) 不应再存在:
    // Container(height:0.5) 渲染为 RenderConstrainedBox(tight h=0.5),渲染层遍历才可捕获。
    expect(
      find.byWidgetPredicate((w) =>
          w is Container &&
          w.constraints == const BoxConstraints.tightFor(height: 0.5)),
      findsNothing,
    );
    final hasHairline = tester.allRenderObjects.any((ro) =>
        ro is RenderConstrainedBox &&
        ro.additionalConstraints ==
            const BoxConstraints.tightFor(height: 0.5));
    expect(hasHairline, isFalse);
  });
}
