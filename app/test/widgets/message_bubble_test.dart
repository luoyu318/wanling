import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/message.dart';
import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/rendering/message_content_renderer.dart';
import 'package:app/widgets/markdown_view.dart';
import 'package:app/widgets/message_bubble.dart';

void main() {
  // 注册内置 renderer（测试前确保注册表就绪）。
  setUpAll(registerBuiltinRenderers);

  group('formatTimestamp', () {
    final now = DateTime(2026, 6, 15, 14, 32);

    test('今天显示 HH:mm', () {
      final t = DateTime(2026, 6, 15, 9, 5);
      expect(formatTimestamp(t, now: now), equals('09:05'));
    });

    test('昨天显示 昨天 HH:mm', () {
      final t = DateTime(2026, 6, 14, 23, 30);
      expect(formatTimestamp(t, now: now), equals('昨天 23:30'));
    });

    test('今年其他天显示 MM-DD HH:mm', () {
      final t = DateTime(2026, 6, 10, 8, 0);
      expect(formatTimestamp(t, now: now), equals('06-10 08:00'));
    });

    test('跨年显示 YYYY-MM-DD HH:mm', () {
      final t = DateTime(2025, 12, 31, 23, 59);
      expect(formatTimestamp(t, now: now), equals('2025-12-31 23:59'));
    });

    test('跨年同 calendar day 但 diff < 24h', () {
      final now2 = DateTime(2026, 1, 1, 0, 30);
      final t = DateTime(2025, 12, 31, 23, 0);
      expect(formatTimestamp(t, now: now2), equals('2025-12-31 23:00'));
    });
  });

  group('BubbleWithTail', () {
    testWidgets('agent 气泡渲染 child 文本', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BubbleWithTail(isMe: false, child: Text('hello')),
        ),
      ));
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('user 气泡也渲染 child', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BubbleWithTail(isMe: true, child: Text('mine')),
        ),
      ));
      expect(find.text('mine'), findsOneWidget);
    });

    testWidgets('包含 CustomPaint（三角）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BubbleWithTail(isMe: false, child: Text('x')),
        ),
      ));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is CustomPaint &&
              w.painter?.runtimeType.toString() == '_TrianglePainter',
        ),
        findsOneWidget,
      );
    });
  });

  group('MessageBubble 内容渲染（注册表分发）', () {
    ChatMessage msg(Map<String, dynamic> content,
            {String senderType = 'agent'}) =>
        ChatMessage(
          id: '1',
          conversationId: 'c1',
          senderType: senderType,
          senderId: 's1',
          content: content,
          createdAt: DateTime(2026, 6, 15, 14, 32),
        );

    testWidgets('text 类型走 BubbleWithTail + Text', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg({'msg_type': 'text', 'data': {'text': 'hi'}}),
            isMe: false,
            baseUrl: 'http://x.com',
            token: 'tok',
          ),
        ),
      ));
      expect(find.byType(BubbleWithTail), findsOneWidget);
      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('markdown 类型(含语法)走 BubbleWithTail + MarkdownView',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg({'msg_type': 'markdown', 'data': {'text': '# hi'}}),
            isMe: false,
            baseUrl: 'http://x.com',
            token: 'tok',
          ),
        ),
      ));
      expect(find.byType(BubbleWithTail), findsOneWidget);
      expect(find.byType(MarkdownView), findsOneWidget);
    });

    testWidgets('image 类型不包 BubbleWithTail', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message:
                msg({'msg_type': 'image', 'data': {'file_id': 'abc'}}),
            isMe: false,
            baseUrl: 'http://x.com',
            token: 'tok',
          ),
        ),
      ));
      expect(find.byType(BubbleWithTail), findsNothing);
      expect(find.byType(CachedNetworkImage), findsOneWidget);
    });

    testWidgets('image fileId 空显示兜底文本', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg({'msg_type': 'image', 'data': {'file_id': ''}}),
            isMe: false,
            baseUrl: 'http://x.com',
            token: 'tok',
          ),
        ),
      ));
      expect(find.text('[图片]'), findsOneWidget);
    });

    testWidgets('file 类型走 BubbleWithTail + 文件名', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg(
                {'msg_type': 'file', 'data': {'filename': 'doc.pdf'}}),
            isMe: false,
            baseUrl: 'http://x.com',
            token: 'tok',
          ),
        ),
      ));
      expect(find.byType(BubbleWithTail), findsOneWidget);
      expect(find.text('doc.pdf'), findsOneWidget);
    });

    testWidgets('file 文件名缺失显示「文件」', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg({'msg_type': 'file', 'data': {'filename': ''}}),
            isMe: false,
            baseUrl: 'http://x.com',
            token: 'tok',
          ),
        ),
      ));
      expect(find.text('文件'), findsOneWidget);
    });

    testWidgets('未知类型走 BubbleWithTail 兜底', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg({'msg_type': 'unknown', 'data': 'something'}),
            isMe: true,
            baseUrl: 'http://x.com',
            token: 'tok',
          ),
        ),
      ));
      expect(find.byType(BubbleWithTail), findsOneWidget);
    });
  });

  group('多选模式', () {
    ChatMessage msg({String senderType = 'agent'}) => ChatMessage(
          id: '1',
          conversationId: 'c1',
          senderType: senderType,
          senderId: 's1',
          content: {'msg_type': 'text', 'data': {'text': 'hi'}},
          createdAt: DateTime(2026, 6, 20),
        );

    final circleCheckFinder = find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).shape == BoxShape.circle,
    );

    testWidgets('selectionMode=true 渲染勾选框', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg(),
            isMe: false,
            baseUrl: '',
            token: '',
            selectionMode: true,
            selected: false,
          ),
        ),
      ));
      expect(circleCheckFinder, findsOneWidget);
      expect(find.text('hi'), findsOneWidget);
    });

    testWidgets('selected=true 渲染选中勾选图标', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg(),
            isMe: true,
            baseUrl: '',
            token: '',
            selectionMode: true,
            selected: true,
          ),
        ),
      ));
      expect(find.byIcon(Icons.check), findsOneWidget);
    });

    testWidgets('非多选模式不渲染勾选框', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg(),
            isMe: false,
            baseUrl: '',
            token: '',
          ),
        ),
      ));
      expect(find.byIcon(Icons.check), findsNothing);
      expect(circleCheckFinder, findsNothing);
    });

    testWidgets('onLongPressStart 回调被触发（含 markdown，regression）',
        (tester) async {
      // Bug 2 回归：markdown 消息长按也要能弹菜单（之前 MarkdownWidget 内置
      // SelectionArea 吞手势，现在改用自控 MarkdownView 无此问题）。
      bool longPressed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: ChatMessage(
              id: '1',
              conversationId: 'c1',
              senderType: 'agent',
              senderId: 's1',
              content: {
                'msg_type': 'markdown',
                'data': {'text': '# 标题\n\n正文'},
              },
              createdAt: DateTime(2026, 6, 20),
            ),
            isMe: false,
            baseUrl: '',
            token: '',
            onLongPressStart: (_) => longPressed = true,
          ),
        ),
      ));
      await tester.longPress(find.text('标题'));
      expect(longPressed, isTrue);
    });

    testWidgets('onLongPressStart 回调被触发（纯文本）', (tester) async {
      bool longPressed = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: msg(),
            isMe: false,
            baseUrl: '',
            token: '',
            onLongPressStart: (_) => longPressed = true,
          ),
        ),
      ));
      await tester.longPress(find.text('hi'));
      expect(longPressed, isTrue);
    });

    testWidgets('多选模式：点气泡本体切换选中', (tester) async {
      var selected = false;
      final message = ChatMessage(
        id: '1',
        conversationId: 'c1',
        senderType: 'agent',
        senderId: 'a1',
        content: {'msg_type': 'text', 'data': {'text': 'hello'}},
        createdAt: DateTime.now(),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            isMe: false,
            baseUrl: '',
            token: '',
            selectionMode: true,
            selected: false,
            onTapSelect: () => selected = !selected,
          ),
        ),
      ));

      await tester.tap(find.text('hello'), warnIfMissed: false);
      await tester.pump();
      expect(selected, isTrue);

      await tester.tap(find.text('hello'), warnIfMissed: false);
      await tester.pump();
      expect(selected, isFalse);
    });

    testWidgets('多选模式：点勾选框也切换选中', (tester) async {
      var selected = false;
      final message = ChatMessage(
        id: '1',
        conversationId: 'c1',
        senderType: 'agent',
        senderId: 'a1',
        content: {'msg_type': 'text', 'data': {'text': 'hi'}},
        createdAt: DateTime.now(),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageBubble(
            message: message,
            isMe: false,
            baseUrl: '',
            token: '',
            selectionMode: true,
            selected: false,
            onTapSelect: () => selected = !selected,
          ),
        ),
      ));

      // 勾选框是最左侧的 22px 圆形容器
      final check = find.byWidgetPredicate(
        (w) => w is Container && w.decoration is BoxDecoration,
      ).first;
      await tester.tap(check);
      await tester.pump();
      expect(selected, isTrue);
    });
  });
}
