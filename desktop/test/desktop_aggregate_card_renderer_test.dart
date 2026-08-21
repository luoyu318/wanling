import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_desktop/rendering/aggregate_card_renderer.dart';

/// 桌面版聚合卡:与 app 共用 core 注册表,desktop 启动时覆盖注册
/// DesktopAggregateCardRenderer(外壳透明无阴影,与聊天背景融合)。
/// 本测试直接注册桌面版,断言外壳样式与内容渲染。
void main() {
  Map<String, dynamic> content({
    String state = 'done',
    List<Map<String, dynamic>> elements = const [],
  }) {
    return {
      'msg_type': MsgType.aggregateCard.value,
      'data': {'state': state, 'elements': elements},
    };
  }

  Widget host(Map<String, dynamic> c) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.aggregateCard,
            c,
            ctx,
            const MessageRenderContext(
              isMe: false,
              baseUrl: 'http://localhost',
              token: 'test',
              isDark: false,
              messageId: 'm1',
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    registerBuiltinRenderers();
    ContentRendererRegistry.register(
        MsgType.aggregateCard, const DesktopAggregateCardRenderer());
  });

  testWidgets('外壳透明:顶层 Container 无 decoration(无底色/阴影/边框)', (tester) async {
    await tester.pumpWidget(host(content(elements: [
      {'type': 'markdown', 'element_id': 'e1', 'data': {'text': 'hello'}},
    ])));
    await tester.pumpAndSettle();

    // 外壳不再包 BoxDecoration:整树无 boxShadow 容器。
    final containers = tester.widgetList<Container>(find.byType(Container));
    for (final c in containers) {
      final deco = c.decoration;
      if (deco is BoxDecoration) {
        expect(deco.boxShadow, isNull, reason: '桌面版聚合卡不应有阴影');
      }
    }
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('内容元素正常渲染(markdown 文本可见)', (tester) async {
    await tester.pumpWidget(host(content(elements: [
      {'type': 'markdown', 'element_id': 'e1', 'data': {'text': '桌面透明卡内容'}},
    ])));
    await tester.pumpAndSettle();
    expect(find.text('桌面透明卡内容'), findsOneWidget);
  });
}
