import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/message.dart';
import 'package:app/models/quote.dart';
import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/widgets/avatar.dart';
import 'package:app/widgets/chat/message_quote_block.dart';
import 'package:app/widgets/chat/message_row.dart';

void main() {
  setUpAll(registerBuiltinRenderers);

  ChatMessage mkMessage({
    String? senderName,
    String? senderAvatarUrl,
    bool isMe = false,
    Quote? quote,
  }) {
    return ChatMessage(
      id: 'm1',
      conversationId: 'c1',
      senderType: 'user',
      senderId: isMe ? 'me' : 'other',
      content: const {
        'msg_type': 'text',
        'data': {'text': 'hello'}
      },
      createdAt: DateTime.parse('2026-07-06T10:00:00Z'),
      senderName: senderName,
      senderAvatarUrl: senderAvatarUrl,
      quote: quote,
    );
  }

  const sampleQuote = Quote(
    messageId: 'q1',
    senderName: '张三',
    senderType: 'user',
    senderId: 'u1',
    msgType: 'text',
    preview: '被引用的内容',
  );

  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(
          body: ProviderScope(child: child),
        ),
      );

  group('MessageRow 接收方布局', () {
    testWidgets('显示头像 + 气泡, 靠左', (tester) async {
      final msg = mkMessage(senderName: '李四');
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: false,
        showAvatar: true,
        showNickname: false,
        baseUrl: '',
        token: '',
      )));
      expect(find.byType(Avatar), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('群聊 + 接收方: 显示昵称', (tester) async {
      final msg = mkMessage(senderName: '李四');
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: true,
        showAvatar: true,
        showNickname: true,
        baseUrl: '',
        token: '',
      )));
      expect(find.text('李四'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('连续消息 showAvatar=false 时仍占位 36px', (tester) async {
      final msg = mkMessage(senderName: '李四');
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: true,
        showAvatar: false,
        showNickname: false,
        baseUrl: '',
        token: '',
      )));
      expect(find.byType(Avatar), findsNothing);
      expect(find.text('hello'), findsOneWidget);
    });
  });

  group('MessageRow 发送方布局', () {
    testWidgets('显示气泡 + 头像, 靠右', (tester) async {
      final msg = mkMessage(isMe: true, senderName: '我');
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: true,
        isGroup: false,
        showAvatar: true,
        showNickname: false,
        baseUrl: '',
        token: '',
      )));
      expect(find.byType(Avatar), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    testWidgets('sending 状态: 气泡左侧有 CircularProgressIndicator', (tester) async {
      final msg = mkMessage(isMe: true, senderName: '我')
          .copyWith(status: MessageStatus.sending);
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: true,
        isGroup: false,
        showAvatar: true,
        showNickname: false,
        baseUrl: '',
        token: '',
      )));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('failed 状态: 气泡左侧有 error icon', (tester) async {
      final msg = mkMessage(isMe: true, senderName: '我')
          .copyWith(status: MessageStatus.failed);
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: true,
        isGroup: false,
        showAvatar: true,
        showNickname: false,
        baseUrl: '',
        token: '',
        onFailedTap: () {},
      )));
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });

  group('MessageRow 多选模式', () {
    testWidgets('selectionMode=true 时隐藏头像', (tester) async {
      final msg = mkMessage(senderName: '李四');
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: true,
        showAvatar: true,
        showNickname: true,
        baseUrl: '',
        token: '',
        selectionMode: true,
      )));
      expect(find.byType(Avatar), findsNothing);
      expect(find.text('李四'), findsNothing);
    });
  });

  group('MessageRow 引用块集成', () {
    testWidgets('接收方 message.quote != null 时引用块在昵称之上渲染', (tester) async {
      final msg = mkMessage(senderName: '李四', quote: sampleQuote);
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: true,
        showAvatar: true,
        showNickname: true,
        baseUrl: '',
        token: '',
      )));
      // 引用块出现
      expect(find.byType(MessageQuoteBlock), findsOneWidget);
      // 引用块的 sender 名(@前缀)+ preview 可见
      expect(find.text('@张三'), findsOneWidget);
      expect(find.text('被引用的内容'), findsOneWidget);
      // 气泡内容仍在
      expect(find.text('hello'), findsOneWidget);
      // 顺序:引用块 → 昵称 → 气泡(用 widget tree 顺序校验)
      final quoteEl = find.byType(MessageQuoteBlock).evaluate().single;
      final nicknameEl = find.text('李四').evaluate().single;
      final bubbleEl = find.text('hello').evaluate().single;
      final columnChildren = tester.widget<Column>(find.ancestor(
        of: find.byType(MessageQuoteBlock),
        matching: find.byType(Column),
      ).first).children;
      final quoteIdx = columnChildren.indexWhere((w) =>
          w is Padding && w.child is MessageQuoteBlock);
      final nicknameIdx = columnChildren.indexWhere((w) =>
          w is Padding && (w.child is Text));
      expect(quoteIdx, greaterThanOrEqualTo(0));
      expect(nicknameIdx, greaterThan(quoteIdx));
      // bubble 也在 column 后面(占位校验:确保引用块在气泡之前)
      expect(columnChildren.last.toString(), isNot(contains('MessageQuoteBlock')));
      // 引用 element 在 columnChildren 中比 nickname 早出现
      expect(quoteEl.toString().length, greaterThan(0));
      expect(nicknameEl.toString().length, greaterThan(0));
      expect(bubbleEl.toString().length, greaterThan(0));
    });

    testWidgets('发送方 message.quote != null 时引用块在气泡之上渲染(方案 B)', (tester) async {
      final msg = mkMessage(isMe: true, senderName: '我', quote: sampleQuote);
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: true,
        isGroup: false,
        showAvatar: true,
        showNickname: false,
        baseUrl: '',
        token: '',
      )));
      expect(find.byType(MessageQuoteBlock), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
      expect(find.byType(Avatar), findsOneWidget);
    });

    testWidgets('isQuoteRevoked=true 时引用块显示「原消息已撤回」', (tester) async {
      final msg = mkMessage(senderName: '李四', quote: sampleQuote);
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: true,
        showAvatar: true,
        showNickname: true,
        baseUrl: '',
        token: '',
        isQuoteRevoked: true,
      )));
      expect(find.text('原消息已撤回'), findsOneWidget);
      // 撤回时不显示原 preview
      expect(find.text('被引用的内容'), findsNothing);
    });

    testWidgets('onJumpToMessage 回调传入时引用块点击触发', (tester) async {
      final msg = mkMessage(senderName: '李四', quote: sampleQuote);
      String? jumpedId;
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: true,
        showAvatar: true,
        showNickname: true,
        baseUrl: '',
        token: '',
        onJumpToMessage: (id) => jumpedId = id,
      )));
      await tester.tap(find.byType(MessageQuoteBlock));
      await tester.pump();
      expect(jumpedId, 'q1');
    });

    testWidgets('quote=null 时不渲染引用块(向后兼容)', (tester) async {
      final msg = mkMessage(senderName: '李四');
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: true,
        showAvatar: true,
        showNickname: true,
        baseUrl: '',
        token: '',
      )));
      expect(find.byType(MessageQuoteBlock), findsNothing);
      expect(find.text('hello'), findsOneWidget);
    });
  });

  group('MessageRow 聚合卡消息间距', () {
    testWidgets('聚合卡消息外层底部 padding 归零(间距交给 renderer)', (tester) async {
      final msg = ChatMessage(
        id: 'm-agg',
        conversationId: 'c1',
        senderType: 'user',
        senderId: 'u1',
        content: const {
          'msg_type': 'aggregate_card',
          'data': {'state': 'done', 'elements': []}
        },
        createdAt: DateTime.parse('2026-07-06T10:00:00Z'),
      );
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: false,
        showAvatar: false,
        showNickname: false,
        reserveAvatarSpace: false,
        baseUrl: '',
        token: '',
      )));
      // MessageRow 外层 Padding bottom 应为 0(聚合卡间距由 renderer segment 控制)
      final paddings = tester.widgetList<Padding>(find.byType(Padding)).toList();
      final hasZeroBottom = paddings.any(
        (p) => (p.padding as EdgeInsets?)?.bottom == 0,
      );
      expect(hasZeroBottom, isTrue);
    });

    testWidgets('普通消息外层底部 padding 保持 8px', (tester) async {
      final msg = mkMessage(senderName: '李四');
      await tester.pumpWidget(wrap(MessageRow(
        message: msg,
        isMe: false,
        isGroup: false,
        showAvatar: true,
        showNickname: false,
        reserveAvatarSpace: true,
        baseUrl: '',
        token: '',
      )));
      final paddings = tester.widgetList<Padding>(find.byType(Padding)).toList();
      expect(
        paddings.any((p) => (p.padding as EdgeInsets?)?.bottom == 8),
        isTrue,
      );
    });
  });
}
