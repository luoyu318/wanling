import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/rendering/truncatable_text_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 审批卡(command/tool)preview 嵌块限高 + 点击抽屉看全文。
/// 终态卡(approved)无 CountdownTimer 周期定时器,pumpAndSettle 安全。
void main() {
  setUpAll(registerBuiltinRenderers);

  Map<String, dynamic> cardContent(String cardType, String preview) {
    return {
      'msg_type': 'card',
      'data': {
        'approval_id': 'test-approval',
        'card_type': cardType,
        'title': '测试审批',
        'preview': preview,
        'state': 'approved',
        'expires_at': DateTime.now().toUtc().toIso8601String(),
        'actions': [
          {'id': 'allow_once', 'label': '允许', 'icon': '', 'style': 'primary'},
        ],
      },
    };
  }

  Widget host(Map<String, dynamic> content, {bool isDark = false}) {
    return MaterialApp(
      darkTheme: ThemeData(brightness: Brightness.dark),
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.card,
            content,
            ctx,
            MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: isDark),
          ),
        ),
      ),
    );
  }

  const longCommand =
      'echo line-1\necho line-2\necho line-3\necho line-4\necho tail-marker-line';

  testWidgets('command 卡长 preview 嵌块限高 56 且挂 TruncatableTextBlock',
      (tester) async {
    await tester.pumpWidget(host(cardContent('command', longCommand)));
    await tester.pumpAndSettle();

    final blocks = tester.widgetList<TruncatableTextBlock>(
        find.byType(TruncatableTextBlock));
    expect(blocks, isNotEmpty);

    final size = tester.getSize(find.byType(TruncatableTextBlock).first);
    expect(size.height, lessThanOrEqualTo(56.0));
  });

  testWidgets('点击 preview 嵌块弹抽屉展示全文', (tester) async {
    await tester.pumpWidget(host(cardContent('command', longCommand)));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TruncatableTextBlock).first);
    await tester.pumpAndSettle();

    final sheetTexts = tester.widgetList<SelectableText>(
        find.byType(SelectableText));
    expect(
      sheetTexts.any((w) => w.data?.contains('tail-marker-line') ?? false),
      isTrue,
    );
  });

  testWidgets('tool 卡 preview 同样走限高嵌块', (tester) async {
    await tester.pumpWidget(host(cardContent('tool', longCommand)));
    await tester.pumpAndSettle();
    expect(find.byType(TruncatableTextBlock), findsOneWidget);
  });

  testWidgets('深色模式 preview 文字适配 C8C8C8(浅色 555555)', (tester) async {
    await tester.pumpWidget(host(cardContent('command', longCommand)));
    await tester.pumpAndSettle();
    final lightColor = tester
        .widget<Text>(find.descendant(
            of: find.byType(TruncatableTextBlock), matching: find.byType(Text)))
        .style
        ?.color;

    await tester.pumpWidget(host(cardContent('command', longCommand),
        isDark: true));
    await tester.pumpAndSettle();
    final darkColor = tester
        .widget<Text>(find.descendant(
            of: find.byType(TruncatableTextBlock), matching: find.byType(Text)))
        .style
        ?.color;

    expect(lightColor, const Color(0xFF555555));
    expect(darkColor, const Color(0xFFC8C8C8));
  });
}
