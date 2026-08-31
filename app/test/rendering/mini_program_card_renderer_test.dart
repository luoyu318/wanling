import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart'
    show ContentRendererRegistry, MessageRenderContext;

/// 构造带 GoRouter 的宿主：initialLocation `/chat/<convId>` 渲染小程序卡片，
/// /mini-program/:appid 目标路由记录跳转 location 供断言。
Widget hostWithRouter({
  required Map<String, dynamic> content,
  String convId = 'conv-1',
  required void Function(String location) onRoute,
  bool isDark = false,
}) {
  final router = GoRouter(
    initialLocation: '/chat/$convId',
    routes: [
      GoRoute(
        path: '/chat/:convId',
        builder: (_, state) => Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.miniProgramCard,
              content,
              ctx,
              MessageRenderContext(
                isMe: false,
                baseUrl: '',
                token: '',
                isDark: isDark,
                convId: state.pathParameters['convId']!,
              ),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/mini-program/:appid',
        builder: (_, state) {
          onRoute(state.uri.toString());
          return const SizedBox.shrink();
        },
      ),
    ],
  );
  return MaterialApp.router(routerConfig: router);
}

void main() {
  setUpAll(() {
    registerBuiltinRenderers();
  });

  testWidgets('卡片渲染 title 且点击跳容器页携带 conv', (tester) async {
    String? jumpedTo;
    await tester.pumpWidget(hostWithRouter(
      content: {
        'msg_type': 'mini_program_card',
        'data': {'appid': 'hello', 'title': 'Hello 示例', 'params': {'k': 'v'}},
      },
      onRoute: (loc) => jumpedTo = loc,
    ));

    expect(find.text('Hello 示例'), findsOneWidget);
    expect(find.text('小程序 · 点击打开'), findsOneWidget);

    await tester.tap(find.text('Hello 示例'));
    await tester.pumpAndSettle();
    expect(jumpedTo, '/mini-program/hello?conv=conv-1');
  });

  testWidgets('缺 appid 的脏数据渲染降级占位(不抛异常,无跳转入口)', (tester) async {
    String? jumpedTo;
    await tester.pumpWidget(hostWithRouter(
      content: {
        'msg_type': 'mini_program_card',
        'data': {'title': '只有标题'},
      },
      onRoute: (loc) => jumpedTo = loc,
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('[小程序卡片]'), findsOneWidget);
    expect(find.text('只有标题'), findsNothing);
    expect(jumpedTo, isNull);
  });

  testWidgets('缺 data 字段的脏数据渲染降级占位(不抛异常)', (tester) async {
    await tester.pumpWidget(hostWithRouter(
      content: {'msg_type': 'mini_program_card'},
      onRoute: (_) {},
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('[小程序卡片]'), findsOneWidget);
  });

  testWidgets('深色模式:卡底 0xFF26272D + 副文字 0xFFAAAAAA(浅色回归白底)', (tester) async {
    bool hasCardBg(WidgetTester tester, Color color) => tester
        .widgetList<Container>(find.byType(Container))
        .any((w) => w.color == color || (w.decoration as BoxDecoration?)?.color == color);

    await tester.pumpWidget(hostWithRouter(
      content: {
        'msg_type': 'mini_program_card',
        'data': {'appid': 'hello', 'title': 'Hello 示例'},
      },
      onRoute: (_) {},
      isDark: true,
    ));
    expect(hasCardBg(tester, const Color(0xFF26272D)), isTrue);
    expect(
      tester.widget<Text>(find.text('小程序 · 点击打开')).style?.color,
      const Color(0xFFAAAAAA),
    );

    await tester.pumpWidget(hostWithRouter(
      content: {
        'msg_type': 'mini_program_card',
        'data': {'appid': 'hello', 'title': 'Hello 示例'},
      },
      onRoute: (_) {},
    ));
    expect(hasCardBg(tester, Colors.white), isTrue);
  });
}
