import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUpAll(registerBuiltinRenderers);

  group('灰底卡片左边框', () {
    testWidgets('tool_call 左边框 3px 信息蓝 #5B8BF7', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCall,
              {
                'msg_type': 'tool_call',
                'data': {'name': 'bash', 'input': {'command': 'ls'}},
              },
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final decoration = container.decoration as BoxDecoration;
      final border = decoration.border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFF5B8BF7));
      // 方案 A:对齐 tool_error,只画 left 边,其余三边 none
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('tool_result 左边框 3px 完成绿 #07C160', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolResult,
              {
                'msg_type': 'tool_result',
                'data': {'name': 'bash', 'output': 'done'},
              },
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final decoration = container.decoration as BoxDecoration;
      final border = decoration.border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFF07C160));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('file_diff 左边框 3px 中性灰 #BBBBBB', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.fileDiff,
              {
                'msg_type': 'file_diff',
                'data': {'file': 'main.dart', 'additions': 5, 'deletions': 2, 'diff': '+ a\n- b'},
              },
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final decoration = container.decoration as BoxDecoration;
      final border = decoration.border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFFBBBBBB));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });
  });

  group('card_renderer 状态感知左边框', () {
    Map<String, dynamic> cardContent(String state) {
      return {
        'msg_type': 'card',
        'data': {
          'approval_id': 'test-approval',
          'card_type': 'command',
          'title': '测试审批',
          'preview': 'ls -la',
          'state': state,
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

    testWidgets('pending 左边框 3px 蓝 #5B8BF7', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.card,
              cardContent('pending'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFF5B8BF7));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('approved 左边框 3px 绿 #07C160', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.card,
              cardContent('approved'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFF07C160));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('denied 左边框 3px 红 #FA5151', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.card,
              cardContent('denied'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFFFA5151));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('expired 左边框 3px 灰 #999999', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.card,
              cardContent('expired'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFF999999));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });
  });

  group('permission_card 状态感知左边框', () {
    Map<String, dynamic> permContent(String status) {
      return {
        'msg_type': 'permission_card',
        'data': {
          'status': status,
          'action': 'bash',
          'resources': ['/tmp'],
          'save': [],
          'metadata': {'command': 'ls'},
          'oc_request_id': 'req-1',
        },
      };
    }

    testWidgets('pending 左边框 3px 琥珀 #FA8C16', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.permissionCard,
              permContent('pending'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFFFA8C16));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('approved 左边框 3px 深绿 #2E7D32', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.permissionCard,
              permContent('approved'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      // 终态卡外层是折叠外壳(无边框),需定位原卡(带左边框)的 Container
      final container = tester.widget<Container>(
        find.byWidgetPredicate((w) =>
            w is Container &&
            (w.decoration as BoxDecoration?)?.border is Border),
      );
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFF2E7D32));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('denied 左边框 3px 深红 #C62828', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.permissionCard,
              permContent('denied'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      // 终态卡外层是折叠外壳(无边框),需定位原卡(带左边框)的 Container
      final container = tester.widget<Container>(
        find.byWidgetPredicate((w) =>
            w is Container &&
            (w.decoration as BoxDecoration?)?.border is Border),
      );
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFFC62828));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('expired 左边框 3px 深灰 #757575', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.permissionCard,
              permContent('expired'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      // 终态卡外层是折叠外壳(无边框),需定位原卡(带左边框)的 Container
      final container = tester.widget<Container>(
        find.byWidgetPredicate((w) =>
            w is Container &&
            (w.decoration as BoxDecoration?)?.border is Border),
      );
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFF757575));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });
  });

  group('question_card 状态感知左边框', () {
    Map<String, dynamic> qContent(String status) {
      return {
        'msg_type': 'question_card',
        'data': {
          'status': status,
          'questions': [
            {
              'header': '确认',
              'question': '是否继续?',
              'options': [
                {'label': '是', 'description': ''}
              ],
              'multiple': false,
              'custom': false,
            },
          ],
          'oc_request_id': 'req-1',
        },
      };
    }

    testWidgets('pending 左边框 3px 紫 #B388FF', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.questionCard,
              qContent('pending'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFFB388FF));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('answered 左边框 3px 深绿 #2E7D32', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.questionCard,
              qContent('answered'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFF2E7D32));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('rejected 左边框 3px 深红 #C62828', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.questionCard,
              qContent('rejected'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFFC62828));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });

    testWidgets('expired 左边框 3px 深灰 #757575', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.questionCard,
              qContent('expired'),
              ctx,
              const MessageRenderContext(
                  isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));
      await tester.pump();
      final container = tester.widget<Container>(find.byType(Container).first);
      final border =
          (container.decoration as BoxDecoration).border as Border;
      expect(border.left.width, 3.0);
      expect(border.left.color, const Color(0xFF757575));
      expect(border.top, BorderSide.none);
      expect(border.right, BorderSide.none);
      expect(border.bottom, BorderSide.none);
    });
  });
}
