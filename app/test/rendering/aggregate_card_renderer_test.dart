import 'package:app/models/msg_type.dart';
import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/rendering/message_content_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    ContentRendererRegistry.reset();
    registerBuiltinRenderers();
  });

  Map<String, dynamic> element(String type, String id, Map<String, dynamic> data) {
    return {
      'type': type,
      'element_id': id,
      'data': data,
    };
  }

  Map<String, dynamic> content({
    String state = 'generating',
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
            ),
          ),
        ),
      ),
    );
  }

  group('header 状态条', () {
    testWidgets('state=generating 显示「回复中」,不显示「完成」', (tester) async {
      await tester.pumpWidget(host(content(state: 'generating')));
      expect(find.text('回复中'), findsOneWidget);
      expect(find.text('完成'), findsNothing);
    });

    testWidgets('state=done 显示「完成」,不显示「回复中」', (tester) async {
      await tester.pumpWidget(host(content(state: 'done')));
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('回复中'), findsNothing);
    });

    testWidgets('state 缺失默认 generating', (tester) async {
      await tester.pumpWidget(host({
        'msg_type': MsgType.aggregateCard.value,
        'data': {'elements': const []},
      }));
      expect(find.text('回复中'), findsOneWidget);
    });
  });

  group('元素分派（复用 ContentRendererRegistry）', () {
    testWidgets('markdown 元素渲染正文', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('markdown', 'markdown_1', {'text': '最终回复正文'}),
        ],
      )));
      expect(find.text('最终回复正文'), findsOneWidget);
    });

    testWidgets('markdown 元素 generating 时正文仍渲染（流式分支）', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'generating',
        elements: [
          element('markdown', 'markdown_1', {'text': '正在输出的正文'}),
        ],
      )));
      expect(find.text('正在输出的正文'), findsOneWidget);
    });

    testWidgets('reasoning 元素渲染思考折叠摘要（1 行文本）', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('reasoning', 'reasoning_1', {'text': '分析需求并设计方案'}),
        ],
      )));
      expect(find.text('分析需求并设计方案'), findsOneWidget);
    });

    testWidgets('tool_card 元素渲染工具列表项', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('tool_card', 'tool_card_1', {
            'name': 'bash',
            'status': 'error',
            'input': {'command': 'ls'},
            'error': '命令失败',
          }),
        ],
      )));
      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('失败'), findsOneWidget);
    });

    testWidgets('compact_divider 元素渲染分隔线', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('compact_divider', 'divider_1', const {}),
        ],
      )));
      expect(find.byType(Divider), findsNothing);
      // 压缩分隔用自绘细线(Container color → ColoredBox 1px #EEEEEE,
      // 不引入 Divider 默认缩进/上下间距)
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .any((c) => c.color == const Color(0xFFEEEEEE)),
        isTrue,
      );
    });

    testWidgets('footer 元素渲染底部信息行（耗时/tokens）', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('footer', 'footer_1', {
            'duration': 12.3,
            'tokens': {'total': 2100},
          }),
        ],
      )));
      expect(find.text('⏱ 12.3s'), findsOneWidget);
      expect(find.text('tokens 2.1k'), findsOneWidget);
    });
  });

  group('元素 data 结构对齐', () {
    testWidgets('tool_card 元素 data 对齐现有 tool_card renderer 消费字段', (tester) async {
      // ToolCardRenderer 读 data.status 决定三态,此处 completed + output 走完成卡
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('tool_card', 'tool_card_1', {
            'name': 'read',
            'status': 'completed',
            'input': {'path': 'lib/main.dart'},
            'output': '<path>lib/main.dart</path>\n<type>file</type>\n<content>\n1: void main()\n</content>',
          }),
        ],
      )));
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('完成'), findsNWidgets(2)); // header + 工具卡状态
    });

    testWidgets('footer 元素 data 对齐 step_finish renderer（cost 字段）', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('footer', 'footer_1', {
            'duration': 1.5,
            'cost': 0.123,
            'tokens': {'total': 800},
          }),
        ],
      )));
      expect(find.text('⏱ 1.5s'), findsOneWidget);
      expect(find.text(r'$0.123'), findsOneWidget);
      expect(find.text('tokens 0.8k'), findsOneWidget);
    });
  });

  group('空守卫', () {
    testWidgets('无 elements 时仅渲染 header', (tester) async {
      await tester.pumpWidget(host(content(state: 'generating')));
      expect(find.text('回复中'), findsOneWidget);
    });
  });
}
