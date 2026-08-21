import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart' show ContentRendererRegistry, MessageRenderContext;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 旧版 hermes 工具调用消息卡(ToolCallRenderer)深色模式适配测试。
/// 色板沿用既定约定:卡底 26272D/FAFAFA、标题 EEEEEE/111111、正文灰阶反转。
void main() {
  setUpAll(() {
    registerBuiltinRenderers();
  });

  Widget renderToolCall(Map<String, dynamic> data, {bool isDark = false}) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.toolCall,
            {'data': data},
            ctx,
            MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: isDark),
          ),
        ),
      ),
    );
  }

  // 卡底 Container 可能走 color 也可能走 decoration.color,两者都查
  bool hasCardBg(WidgetTester tester, Color color) => tester
      .widgetList<Container>(find.byType(Container))
      .any((w) => w.color == color || (w.decoration as BoxDecoration?)?.color == color);

  group('ToolCallRenderer 深色模式适配', () {
    testWidgets('bash 卡:深色底 26272D + 标题 EEEEEE(浅色回归 FAFAFA/111111)', (tester) async {
      final data = {'name': 'bash', 'input': {'command': 'ls'}};
      await tester.pumpWidget(renderToolCall(data, isDark: true));
      expect(hasCardBg(tester, const Color(0xFF26272D)), isTrue);
      expect(tester.widget<Text>(find.text('Bash')).style?.color, const Color(0xFFEEEEEE));

      await tester.pumpWidget(renderToolCall(data));
      expect(hasCardBg(tester, const Color(0xFFFAFAFA)), isTrue);
      expect(tester.widget<Text>(find.text('Bash')).style?.color, const Color(0xFF111111));
    });

    testWidgets('read body 透传 isDark:块底深浅切换 + 抽屉路径字灰阶反转', (tester) async {
      final data = {'name': 'read', 'input': {'filePath': '/src/main.go'}};
      // 深色:块底 26272D,点击弹抽屉全路径 C8C8C8
      await tester.pumpWidget(renderToolCall(data, isDark: true));
      expect(hasCardBg(tester, const Color(0xFF26272D)), isTrue);
      await tester.tap(find.text('main.go'));
      await tester.pumpAndSettle();
      expect(find.textContaining('/src/main.go'), findsOneWidget);
      // find.text 会命中 SelectableText 内部的 EditableText,直接按类型取
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).style?.color, const Color(0xFFC8C8C8));

      // 浅色回归:块底 F2F2F2(区别于卡底 FAFAFA,证明 isDark 传参生效),抽屉路径字 555555
      // 先点 barrier 关掉深色抽屉(模态 route 不随 pumpWidget 换树消失)
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.pumpWidget(renderToolCall(data));
      expect(hasCardBg(tester, const Color(0xFFF2F2F2)), isTrue);
      await tester.tap(find.text('main.go'));
      await tester.pumpAndSettle();
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).style?.color, const Color(0xFF555555));
    });

    testWidgets('task 卡:深色描述 C8C8C8(浅色回归 555555)', (tester) async {
      final data = {'name': 'task', 'input': {'description': '调研一下', 'subagent_type': 'general'}};
      await tester.pumpWidget(renderToolCall(data, isDark: true));
      expect(tester.widget<Text>(find.text('调研一下')).style?.color, const Color(0xFFC8C8C8));

      await tester.pumpWidget(renderToolCall(data));
      expect(tester.widget<Text>(find.text('调研一下')).style?.color, const Color(0xFF555555));
    });

    testWidgets('未识别工具 fallback:深色内联字 AAAAAA(浅色回归 666666)', (tester) async {
      final data = {'name': 'unknown_tool', 'input': {'foo': 'bar'}};
      await tester.pumpWidget(renderToolCall(data, isDark: true));
      expect(tester.widget<Text>(find.textContaining('{foo: bar}')).style?.color, const Color(0xFFAAAAAA));

      await tester.pumpWidget(renderToolCall(data));
      expect(tester.widget<Text>(find.textContaining('{foo: bar}')).style?.color, const Color(0xFF666666));
    });
  });
}
