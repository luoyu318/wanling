import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// FileDiffRenderer 深色模式适配测试。
/// 色板沿用既定约定:卡底 26272D/FAFAFA、抽屉底 1E1F24/白、标题 EEEEEE/111111、
/// 正文灰阶反转;语义色(新增绿 07C160/删除红 FA5151)两态一致。
void main() {
  setUpAll(registerBuiltinRenderers);

  final diffData = {
    'msg_type': MsgType.fileDiff.value,
    'data': {
      'file': 'main.dart',
      'additions': 5,
      'deletions': 2,
      'diff': '+ added line\n context line\n- removed line',
    },
  };

  Widget host({bool isDark = false}) {
    return MaterialApp(
      darkTheme: ThemeData(brightness: Brightness.dark),
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.fileDiff,
            diffData,
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

  // 抽屉内按 BottomSheet 子树精确定位(卡在页面层,同名 Text 会命中两次)
  Material sheetMaterial(WidgetTester tester) => tester.widget<Material>(
        find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first,
      );

  group('FileDiffRenderer 卡片深浅成对', () {
    testWidgets('深色卡底 26272D + 标题 EEEEEE + ▸ 777777(浅色回归 FAFAFA/111111/999999)', (tester) async {
      await tester.pumpWidget(host(isDark: true));
      expect(hasCardBg(tester, const Color(0xFF26272D)), isTrue);
      expect(
        tester.widget<Text>(find.text('main.dart')).style?.color,
        const Color(0xFFEEEEEE),
      );
      expect(
        tester.widget<Text>(find.text('▸')).style?.color,
        const Color(0xFF777777),
      );
      // 语义色保留:+ 绿 / − 红
      expect(tester.widget<Text>(find.text('+5')).style?.color, const Color(0xFF07C160));
      expect(tester.widget<Text>(find.text('−2')).style?.color, const Color(0xFFFA5151));

      await tester.pumpWidget(host());
      expect(hasCardBg(tester, const Color(0xFFFAFAFA)), isTrue);
      expect(
        tester.widget<Text>(find.text('main.dart')).style?.color,
        const Color(0xFF111111),
      );
      expect(
        tester.widget<Text>(find.text('▸')).style?.color,
        const Color(0xFF999999),
      );
    });
  });

  group('FileDiffRenderer 抽屉深浅成对', () {
    testWidgets('深色抽屉:底 1E1F24 + 把手 3A3B42 + 分割线 2E2F36 + 标题 EEEEEE + 普通行 777777', (tester) async {
      await tester.pumpWidget(host(isDark: true));
      await tester.tap(find.byType(GestureDetector));
      await tester.pumpAndSettle();

      expect(sheetMaterial(tester).color, const Color(0xFF1E1F24));
      // 把手 36x4 Container
      expect(
        tester
            .widgetList<Container>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Container)))
            .any((w) => (w.decoration as BoxDecoration?)?.color == const Color(0xFF3A3B42)),
        isTrue,
      );
      expect(
        tester.widget<Divider>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Divider))).color,
        const Color(0xFF2E2F36),
      );
      expect(
        tester.widget<Text>(find.descendant(of: find.byType(BottomSheet), matching: find.text('main.dart'))).style?.color,
        const Color(0xFFEEEEEE),
      );
      // 普通行灰阶反转;新增绿/删除红语义色保留
      expect(
        tester.widget<Text>(find.text(' context line')).style?.color,
        const Color(0xFF777777),
      );
      expect(tester.widget<Text>(find.text('+ added line')).style?.color, const Color(0xFF07C160));
      expect(tester.widget<Text>(find.text('- removed line')).style?.color, const Color(0xFFFA5151));
    });

    testWidgets('浅色抽屉回归:白底 + 把手 DDDDDD + 分割线 EEEEEE + 标题 333333 + 普通行 999999', (tester) async {
      await tester.pumpWidget(host());
      await tester.tap(find.byType(GestureDetector));
      await tester.pumpAndSettle();

      expect(sheetMaterial(tester).color, Colors.white);
      expect(
        tester
            .widgetList<Container>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Container)))
            .any((w) => (w.decoration as BoxDecoration?)?.color == const Color(0xFFDDDDDD)),
        isTrue,
      );
      expect(
        tester.widget<Divider>(find.descendant(of: find.byType(BottomSheet), matching: find.byType(Divider))).color,
        const Color(0xFFEEEEEE),
      );
      expect(
        tester.widget<Text>(find.descendant(of: find.byType(BottomSheet), matching: find.text('main.dart'))).style?.color,
        const Color(0xFF333333),
      );
      expect(
        tester.widget<Text>(find.text(' context line')).style?.color,
        const Color(0xFF999999),
      );
    });
  });
}
