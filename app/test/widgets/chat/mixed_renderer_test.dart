import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/chat/builtin_renderers.dart';
import 'package:app/widgets/chat/message_bubble.dart';

void main() {
  setUp(() {
    // 每个测试前重置 + 注册内置 + 注册 mixed，保证隔离。
    ContentRendererRegistry.reset();
    registerBuiltinRenderers();
    registerMixedContentRenderer();
  });

  // 与 content_renderer_registry_test 同款 harness：Builder 取真实 BuildContext，
  // rc 用最小构造（isMe/baseUrl/token/isDark 必填，其余字段默认值）。
  Widget host(Map<String, dynamic> content) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.mixed,
            content,
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

  testWidgets('mixed: 渲染图片+文字两个气泡', (tester) async {
    final content = {
      'msg_type': 'mixed',
      'data': {
        'text': '看这张',
        'items': [
          {'type': 'image', 'file_id': 'f1'},
        ],
      },
    };
    await tester.pumpWidget(host(content));
    // 断言:两个 BubbleWithTail;文字'看这张'可见
    expect(find.byType(BubbleWithTail), findsNWidgets(2));
    expect(find.text('看这张'), findsOneWidget);
  });

  testWidgets('mixed: 无 text 只渲染图片单气泡', (tester) async {
    final content = {
      'msg_type': 'mixed',
      'data': {
        'items': [
          {'type': 'image', 'file_id': 'f1'},
        ],
      },
    };
    await tester.pumpWidget(host(content));
    // 断言:仅图片一个气泡,无文字气泡
    expect(find.byType(BubbleWithTail), findsNWidgets(1));
    expect(find.text('看这张'), findsNothing);
  });
}
