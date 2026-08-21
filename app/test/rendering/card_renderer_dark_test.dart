import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// CardContentRenderer(审批卡)深色模式适配测试。
/// 色板沿用既定约定:外壳/嵌块底 26272D ↔ 白/F2F2F2;语义色
/// (FA8C16 橙色警示、左边框状态色)两态一致。
///
/// 注意:pending 卡含 CountdownTimer(Timer.periodic 每秒 setState),
/// 断言用 pump(Duration) 而非 pumpAndSettle,避免周期定时器永不 settle 超时。
void main() {
  setUpAll(registerBuiltinRenderers);

  Map<String, dynamic> cardContent() {
    return {
      'msg_type': 'card',
      'data': {
        'approval_id': 'test-approval',
        'card_type': 'command',
        'title': '测试审批',
        'preview': 'ls -la',
        'state': 'pending',
        'actions': [
          {'id': 'allow_once', 'label': '允许', 'icon': '', 'style': 'primary'},
        ],
        'expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      },
    };
  }

  Widget host({bool isDark = false}) {
    return MaterialApp(
      darkTheme: ThemeData(brightness: Brightness.dark),
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.card,
            cardContent(),
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

  testWidgets('审批卡外壳深浅成对:深色 26272D(浅色回归白底)', (tester) async {
    // CountdownTimer 周期性 Timer:只 pump 固定时长,不 pumpAndSettle
    await tester.pumpWidget(host(isDark: true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(hasCardBg(tester, const Color(0xFF26272D)), isTrue);

    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 100));
    expect(hasCardBg(tester, Colors.white), isTrue);
  });

  testWidgets('命令预览嵌块深浅成对:深色 26272D(浅色回归 F2F2F2)', (tester) async {
    await tester.pumpWidget(host(isDark: true));
    await tester.pump(const Duration(milliseconds: 100));
    // 外壳与嵌块同为 26272D:至少出现两次(外壳 + preview 嵌块)
    final darkBlocks = tester
        .widgetList<Container>(find.byType(Container))
        .where((w) => w.color == const Color(0xFF26272D) || (w.decoration as BoxDecoration?)?.color == const Color(0xFF26272D))
        .length;
    expect(darkBlocks, greaterThanOrEqualTo(2));

    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 100));
    expect(hasCardBg(tester, const Color(0xFFF2F2F2)), isTrue);
  });

  testWidgets('语义色保留:橙色警示 meta 两态一致 FA8C16', (tester) async {
    final warn = {
      'msg_type': 'card',
      'data': {
        'approval_id': 'test-approval',
        'card_type': 'command',
        'title': '测试审批',
        'preview': 'ls -la',
        'state': 'pending',
        'meta': [
          {'icon': '⚠️', 'text': '高风险操作', 'warn': true},
        ],
        'actions': [
          {'id': 'allow_once', 'label': '允许', 'icon': '', 'style': 'primary'},
        ],
        'expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      },
    };
    Widget warnHost({bool isDark = false}) {
      return MaterialApp(
        darkTheme: ThemeData(brightness: Brightness.dark),
        themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.card,
              warn,
              ctx,
              MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: isDark),
            ),
          ),
        ),
      );
    }

    await tester.pumpWidget(warnHost(isDark: true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<Text>(find.textContaining('高风险操作')).style?.color,
      const Color(0xFFFA8C16),
    );

    await tester.pumpWidget(warnHost());
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.widget<Text>(find.textContaining('高风险操作')).style?.color,
      const Color(0xFFFA8C16),
    );
  });
}
