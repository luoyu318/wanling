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

  testWidgets('mixed: 图片裸图渲染+文字气泡,条目间距 16', (tester) async {
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
    // 断言:图片走裸图(Hero,同普通图片消息),仅文字包 BubbleWithTail;
    // 条目间有 16px 间距(对齐相邻两条普通消息的视觉间距)
    expect(find.byType(Hero), findsOneWidget);
    expect(find.byType(BubbleWithTail), findsOneWidget);
    expect(find.text('看这张'), findsOneWidget);
    final gap = find.byWidgetPredicate(
      (w) => w is SizedBox && w.height == 16,
    );
    expect(gap, findsOneWidget);
  });

  testWidgets('mixed: 无 text 只渲染裸图,无气泡', (tester) async {
    final content = {
      'msg_type': 'mixed',
      'data': {
        'items': [
          {'type': 'image', 'file_id': 'f1'},
        ],
      },
    };
    await tester.pumpWidget(host(content));
    // 断言:仅裸图(Hero),无任何气泡壳
    expect(find.byType(Hero), findsOneWidget);
    expect(find.byType(BubbleWithTail), findsNothing);
    expect(find.text('看这张'), findsNothing);
  });
}
