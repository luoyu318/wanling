import 'package:app/models/message.dart';
import 'package:app/models/msg_type.dart';
import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/rendering/message_content_renderer.dart' show ContentRendererRegistry, MessageRenderContext;
import 'package:app/rendering/truncatable_text_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  setUpAll(() {
    registerBuiltinRenderers();
  });

  Map<String, dynamic> makeTaskContent({
    required String status,
    String subSessionId = 'ses-child-1',
    double? duration,
  }) {
    return {
      'data': {
        'name': 'task',
        'status': status,
        'input': {'description': '调研一下', 'subagent_type': 'general'},
        if (subSessionId.isNotEmpty) 'sub_session_id': subSessionId,
        if (duration != null) 'duration': duration,
      },
    };
  }

  group('ToolCardRenderer', () {
    Map<String, dynamic> makeContent({
      required String status,
      required String name,
      Map<String, dynamic>? input,
      String? output,
      String? error,
      Map<String, dynamic>? fileDiff,
    }) {
      return {
        'data': {
          'status': status,
          'name': name,
          if (input != null) 'input': input,
          if (output != null) 'output': output,
          if (error != null) 'error': error,
          if (fileDiff != null) 'file_diff': fileDiff,
        },
      };
    }

    testWidgets('running 状态: 工具名 + 进行中指示', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(status: 'running', name: 'bash', input: {'command': 'ls -la'}),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('Bash'), findsOneWidget);
      expect(find.textContaining('进行中'), findsOneWidget);
      expect(find.textContaining('ls -la'), findsOneWidget);
    });

    testWidgets('completed 状态: 工具名 + 完成标签 + output', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(status: 'completed', name: 'bash', input: {'command': 'ls'}, output: 'total 100'),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('total 100'), findsOneWidget);
    });

    testWidgets('error 状态: 工具名 + 失败标签 + error 文本', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(status: 'error', name: 'bash', input: {'command': 'ls'}, error: 'command not found'),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('失败'), findsOneWidget);
      expect(find.text('command not found'), findsOneWidget);
    });

    testWidgets('completed + file_diff 渲染 file_diff 行', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(
                status: 'completed',
                name: 'edit',
                input: {'filePath': 'main.go', 'oldString': 'foo', 'newString': 'bar'},
                output: 'edited',
                fileDiff: {'file': 'main.go', 'additions': 1, 'deletions': 1, 'diff': '- foo\n+ bar'},
              ),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('Edit'), findsOneWidget);
      expect(find.textContaining('+1'), findsOneWidget);
      expect(find.textContaining('−1'), findsOneWidget);
    });

    testWidgets('completed output > 80 字符显示截断组件', (tester) async {
      final longOutput = 'a' * 100;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(status: 'completed', name: 'read', output: longOutput),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('Read'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is GestureDetector && w.onTap != null),
        findsOneWidget,
      );
    });

    testWidgets('completed 无 output 不崩溃', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(status: 'completed', name: 'read', input: {'filePath': 'test.txt'}),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('Read'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
    });

    testWidgets('未识别工具名 + 非空 input 走 TruncatableTextBlock fallback', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCall,
              makeContent(status: 'completed', name: 'unknown_tool', input: {'foo': 'bar'}),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      // 标题 capitalize(name): unknown_tool → Unknown_tool
      expect(find.text('Unknown_tool'), findsOneWidget);
      // fallback 渲染 TruncatableTextBlock,内联 Text 含 input.toString()
      expect(find.byType(TruncatableTextBlock), findsOneWidget);
      expect(find.textContaining('{foo: bar}'), findsOneWidget);
      // 挂 GestureDetector 支持点击弹抽屉看全文
      expect(
        find.byWidgetPredicate((w) => w is GestureDetector && w.onTap != null),
        findsOneWidget,
      );
    });

    testWidgets('未识别工具名 + 空 input 不渲染 body', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCall,
              makeContent(status: 'completed', name: 'unknown_tool'),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('Unknown_tool'), findsOneWidget);
      expect(find.byType(TruncatableTextBlock), findsNothing);
    });

    testWidgets('toolCard 未识别工具名 + 非空 input → input body 走 TruncatableTextBlock', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(status: 'running', name: 'mystery_tool', input: {'k': 'v'}),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('Mystery_tool'), findsOneWidget);
      expect(find.byType(TruncatableTextBlock), findsOneWidget);
      expect(find.textContaining('{k: v}'), findsOneWidget);
    });

    testWidgets('toolCard completed + 未识别工具名 + 长 output → 截断分支走 TruncatableTextBlock', (tester) async {
      final longOutput = 'x' * 100;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(status: 'completed', name: 'mystery_tool', output: longOutput),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('Mystery_tool'), findsOneWidget);
      expect(find.byType(TruncatableTextBlock), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is GestureDetector && w.onTap != null),
        findsOneWidget,
      );
    });
  });

  group('ToolCardRenderer task 三态', () {
    testWidgets('starting 态显示已启动文案 + 子 Agent 徽章', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'starting'),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false, convId: 'conv-1'),
            ),
          ),
        ),
      ));

      expect(find.textContaining('已启动'), findsOneWidget);
      expect(find.text('子 Agent'), findsOneWidget);
      expect(find.text('general'), findsOneWidget);
      expect(find.text('调研一下'), findsOneWidget);
    });

    testWidgets('working 态显示正在执行', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'working'),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false, convId: 'conv-1'),
            ),
          ),
        ),
      ));

      expect(find.textContaining('正在执行'), findsOneWidget);
      expect(find.text('子 Agent'), findsOneWidget);
    });

    testWidgets('completed 态显示完成 + 耗时', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'completed', duration: 12.5),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false, convId: 'conv-1'),
            ),
          ),
        ),
      ));

      expect(find.textContaining('完成'), findsOneWidget);
      expect(find.textContaining('12.5'), findsOneWidget);
      expect(find.text('子 Agent'), findsOneWidget);
    });

    testWidgets('completed 无 duration 仅显示完成', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'completed'),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false, convId: 'conv-1'),
            ),
          ),
        ),
      ));

      expect(find.text('完成'), findsOneWidget);
    });

    testWidgets('sub_session_id 非空时挂 GestureDetector', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'working', subSessionId: 'ses-child-1'),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false, convId: 'conv-1'),
            ),
          ),
        ),
      ));

      expect(
        find.byWidgetPredicate((w) => w is GestureDetector && w.onTap != null),
        findsOneWidget,
      );
    });

    testWidgets('sub_session_id 为空时不挂 GestureDetector', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'working', subSessionId: ''),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false, convId: 'conv-1'),
            ),
          ),
        ),
      ));

      expect(find.byType(GestureDetector), findsNothing);
    });

    testWidgets('task 卡片聚合 pending 子审批卡 → 渲染 ⚡ 待审批条', (tester) async {
      final pendingApproval = ChatMessage.fromJson({
        'id': 'perm-pending-1',
        'conversation_id': 'conv-1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'permission_card',
          'data': {'status': 'pending', 'action': 'bash'},
        },
        'parent_msg_id': 'task-msg-1',
        'created_at': '2026-07-15T10:00:00Z',
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'working'),
              ctx,
              MessageRenderContext(
                isMe: false, baseUrl: '', token: '', isDark: false,
                convId: 'conv-1',
                messageId: 'task-msg-1',
                conversationMessages: [pendingApproval],
              ),
            ),
          ),
        ),
      ));

      expect(find.textContaining('待审批'), findsOneWidget);
      expect(find.byIcon(Icons.bolt), findsOneWidget);
    });

    testWidgets('子审批卡 parent 不匹配时不渲染审批条', (tester) async {
      final otherApproval = ChatMessage.fromJson({
        'id': 'perm-other',
        'conversation_id': 'conv-1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'permission_card',
          'data': {'status': 'pending', 'action': 'bash'},
        },
        'parent_msg_id': 'other-task-msg',
        'created_at': '2026-07-15T10:00:00Z',
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'working'),
              ctx,
              MessageRenderContext(
                isMe: false, baseUrl: '', token: '', isDark: false,
                convId: 'conv-1',
                messageId: 'task-msg-1',
                conversationMessages: [otherApproval],
              ),
            ),
          ),
        ),
      ));

      expect(find.textContaining('待审批'), findsNothing);
    });

    testWidgets('子审批卡 status=approved 时不渲染审批条', (tester) async {
      final approvedApproval = ChatMessage.fromJson({
        'id': 'perm-approved',
        'conversation_id': 'conv-1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'permission_card',
          'data': {'status': 'approved', 'action': 'bash'},
        },
        'parent_msg_id': 'task-msg-1',
        'created_at': '2026-07-15T10:00:00Z',
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'working'),
              ctx,
              MessageRenderContext(
                isMe: false, baseUrl: '', token: '', isDark: false,
                convId: 'conv-1',
                messageId: 'task-msg-1',
                conversationMessages: [approvedApproval],
              ),
            ),
          ),
        ),
      ));

      expect(find.textContaining('待审批'), findsNothing);
    });

    testWidgets('无 sub_session_id 的 task 不渲染审批条', (tester) async {
      final pendingApproval = ChatMessage.fromJson({
        'id': 'perm-pending-2',
        'conversation_id': 'conv-1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'permission_card',
          'data': {'status': 'pending', 'action': 'bash'},
        },
        'parent_msg_id': 'task-msg-2',
        'created_at': '2026-07-15T10:00:00Z',
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'working', subSessionId: ''),
              ctx,
              MessageRenderContext(
                isMe: false, baseUrl: '', token: '', isDark: false,
                convId: 'conv-1',
                messageId: 'task-msg-2',
                conversationMessages: [pendingApproval],
              ),
            ),
          ),
        ),
      ));

      expect(find.textContaining('待审批'), findsNothing);
    });

    testWidgets('点击 permission_card chip 弹出权限审批抽屉', (tester) async {
      final pendingApproval = ChatMessage.fromJson({
        'id': 'perm-pending-tap',
        'conversation_id': 'conv-1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'permission_card',
          'data': {
            'status': 'pending',
            'action': 'bash',
            'oc_request_id': 'req-1',
            'resources': ['/tmp'],
            'metadata': {'command': 'ls'},
            'save': [],
          },
        },
        'parent_msg_id': 'task-msg-tap',
        'created_at': '2026-07-16T10:00:00Z',
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'completed'),
              ctx,
              MessageRenderContext(
                isMe: false, baseUrl: '', token: '', isDark: false,
                convId: 'conv-1',
                messageId: 'task-msg-tap',
                conversationMessages: [pendingApproval],
              ),
            ),
          ),
        ),
      ));

      // 点击 ⚡ 待审批条
      await tester.tap(find.textContaining('待审批'));
      await tester.pumpAndSettle();

      // 抽屉头部「权限审批」标题应可见
      expect(find.text('权限审批'), findsOneWidget);
      // 动作标签(_permissionLabel('bash') = '执行命令')
      expect(find.text('执行命令'), findsOneWidget);
    });

    testWidgets('点击 question_card chip 弹出选择题抽屉', (tester) async {
      final pendingQuestion = ChatMessage.fromJson({
        'id': 'q-pending-tap',
        'conversation_id': 'conv-1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'question_card',
          'data': {
            'status': 'pending',
            'oc_request_id': 'req-2',
            'questions': [
              {
                'header': '选择路径',
                'question': '用哪个分支?',
                'options': [
                  {'label': 'main', 'description': ''},
                  {'label': 'dev', 'description': ''}
                ],
                'multiple': false,
                'custom': false,
              }
            ],
          },
        },
        'parent_msg_id': 'task-msg-q',
        'created_at': '2026-07-16T10:00:00Z',
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'completed'),
              ctx,
              MessageRenderContext(
                isMe: false, baseUrl: '', token: '', isDark: false,
                convId: 'conv-1',
                messageId: 'task-msg-q',
                conversationMessages: [pendingQuestion],
              ),
            ),
          ),
        ),
      ));

      // chip 当前用 action 字段做副标题,question_card 无 action → 仅显示「待审批」
      await tester.tap(find.textContaining('待审批'));
      await tester.pumpAndSettle();

      // 抽屉头部「选择题」标题
      expect(find.text('选择题'), findsOneWidget);
      // 题干
      expect(find.text('用哪个分支?'), findsOneWidget);
    });
  });

  group('task 卡跳转子 Agent 详情页用 rootMessageId', () {
    Widget hostWithRouter({
      required String messageId,
      String rootMessageId = '',
      required void Function(String taskCardId) onSubagentRoute,
    }) {
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: Builder(
                builder: (ctx) => ContentRendererRegistry.render(
                  MsgType.toolCard,
                  makeTaskContent(status: 'working'),
                  ctx,
                  MessageRenderContext(
                    isMe: false, baseUrl: '', token: '', isDark: false,
                    convId: 'conv-1',
                    messageId: messageId,
                    rootMessageId: rootMessageId,
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/chat/subagent/:taskCardId',
            builder: (_, state) {
              onSubagentRoute(state.pathParameters['taskCardId']!);
              return const SizedBox.shrink();
            },
          ),
        ],
      );
      return MaterialApp.router(routerConfig: router);
    }

    testWidgets('rootMessageId 非空时跳转用它而非 messageId（聚合卡场景）', (tester) async {
      String? jumpedTo;
      await tester.pumpWidget(hostWithRouter(
        messageId: 'tool_card_5',
        rootMessageId: 'agg-msg-real-1',
        onSubagentRoute: (id) => jumpedTo = id,
      ));

      await tester.tap(find.text('general'));
      await tester.pumpAndSettle();

      expect(jumpedTo, 'agg-msg-real-1');
    });

    testWidgets('rootMessageId 缺省时 fallback 到 messageId（非聚合场景）', (tester) async {
      String? jumpedTo;
      await tester.pumpWidget(hostWithRouter(
        messageId: 'task-msg-1',
        rootMessageId: '',
        onSubagentRoute: (id) => jumpedTo = id,
      ));

      await tester.tap(find.text('general'));
      await tester.pumpAndSettle();

      expect(jumpedTo, 'task-msg-1');
    });
  });

  group('ToolCardRenderer 高度平滑过渡', () {
    Map<String, dynamic> makeContent({
      required String status,
      required String name,
      Map<String, dynamic>? input,
      String? output,
    }) {
      return {
        'data': {
          'status': status,
          'name': name,
          if (input != null) 'input': input,
          if (output != null) 'output': output,
        },
      };
    }

    testWidgets('running→completed PATCH 增高时 AnimatedSize 平滑展开', (tester) async {
      Widget render(String status) => MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (ctx) => ContentRendererRegistry.render(
                  MsgType.toolCard,
                  makeContent(
                    status: status,
                    name: 'bash',
                    input: {'command': 'ls -la'},
                    output: 'total 100',
                  ),
                  ctx,
                  const MessageRenderContext(
                      isMe: false, baseUrl: '', token: '', isDark: false),
                ),
              ),
            ),
          );

      await tester.pumpWidget(render('running'));
      expect(find.byType(AnimatedSize), findsOneWidget,
          reason: 'tool_card 应包 AnimatedSize 支撑 PATCH 增高平滑过渡');
      final h0 = tester.getSize(find.byType(AnimatedSize)).height;

      await tester.pumpWidget(render('completed'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      final mid = tester.getSize(find.byType(AnimatedSize)).height;

      await tester.pumpAndSettle();
      final h1 = tester.getSize(find.byType(AnimatedSize)).height;

      expect(h1, greaterThan(h0), reason: 'completed 含 output 应更高');
      expect(mid, greaterThan(h0), reason: '动画中应高于起始高度');
      expect(mid, lessThan(h1), reason: '动画中应低于目标高度(平滑过渡非瞬间)');
    });
  });
}
