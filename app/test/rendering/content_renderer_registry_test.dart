import 'package:app/models/msg_type.dart';
import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/rendering/message_content_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ContentRendererRegistry', () {
    setUp(() {
      // 每个测试前重置 + 注册内置，保证隔离。
      ContentRendererRegistry.reset();
      registerBuiltinRenderers();
    });

    test('内置 renderer 全部注册', () {
      expect(ContentRendererRegistry.get(MsgType.text), isNotNull);
      expect(ContentRendererRegistry.get(MsgType.markdown), isNotNull);
      expect(ContentRendererRegistry.get(MsgType.image), isNotNull);
      expect(ContentRendererRegistry.get(MsgType.file), isNotNull);
    });

    test('text/markdown 可选，image/file 不可选', () {
      expect(ContentRendererRegistry.isSelectable(MsgType.text), isTrue);
      expect(ContentRendererRegistry.isSelectable(MsgType.markdown), isTrue);
      expect(ContentRendererRegistry.isSelectable(MsgType.image), isFalse);
      expect(ContentRendererRegistry.isSelectable(MsgType.file), isFalse);
    });

    test('text/markdown/file 包气泡，image 不包', () {
      expect(ContentRendererRegistry.shouldWrapInBubble(MsgType.text), isTrue);
      expect(ContentRendererRegistry.shouldWrapInBubble(MsgType.markdown),
          isTrue);
      expect(ContentRendererRegistry.shouldWrapInBubble(MsgType.file), isTrue);
      expect(ContentRendererRegistry.shouldWrapInBubble(MsgType.image),
          isFalse);
    });

    testWidgets('未知类型降级到 UnknownRenderer（不崩溃）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.unknown,
              {'msg_type': 'unknown'},
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      // UnknownRenderer 把 content toString 显示，不抛异常
      expect(find.textContaining('msg_type'), findsOneWidget);
    });

    test('register 覆盖旧 renderer（便于测试隔离）', () {
      final custom = _CustomRenderer();
      ContentRendererRegistry.register(MsgType.text, custom);
      expect(identical(ContentRendererRegistry.get(MsgType.text), custom),
          isTrue);
    });

    test('reset 清空注册表', () {
      ContentRendererRegistry.reset();
      expect(ContentRendererRegistry.get(MsgType.text), isNull);
      expect(ContentRendererRegistry.isSelectable(MsgType.text), isFalse);
    });
  });
}

class _CustomRenderer implements MessageContentRenderer {
  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => true;

  @override
  Widget build(context, content, rc) => const Text('custom');
}
