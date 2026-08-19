import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart' show ContentRendererRegistry, MessageRenderContext;
import 'package:wanling_core/rendering/truncatable_text_block.dart';
import 'package:wanling_core/utils/icon_font.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 判断文本是否可命中(高度被裁剪为 0 时不可点,但 widget 仍在树里)。
/// 折叠卡收起时内容用 Align(heightFactor:0)+ClipRect 裁剪,文本节点存在但
/// 渲染面积 0,不能靠 findsNothing 断言。
bool _isTextTappable(WidgetTester tester, String text) {
  final finder = find.text(text);
  if (finder.evaluate().isEmpty) return false;
  return finder.hitTestable().evaluate().isNotEmpty;
}

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

    testWidgets('todowrite 渲染任务清单折叠卡(不隐藏)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(
                status: 'completed',
                name: 'todowrite',
                input: {
                  'todos': [
                    {'content': '任务A', 'status': 'completed'},
                    {'content': '任务B', 'status': 'pending'},
                  ],
                },
              ),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      // 无工具卡外壳,直接折叠行:已完成 x/y 项
      expect(find.text('Todowrite'), findsNothing);
      expect(find.text('已完成 1/2 项'), findsOneWidget);
      // 折叠态:任务行被高度裁剪不可点
      expect(_isTextTappable(tester, '任务A'), isFalse);
      // 点击标题展开 → 任务列表可见(等 AnimatedSize 动画结束)
      await tester.tap(find.text('已完成 1/2 项'));
      await tester.pumpAndSettle();
      expect(_isTextTappable(tester, '任务A'), isTrue);
      expect(_isTextTappable(tester, '任务B'), isTrue);
    });

    testWidgets('edit input 拆上下两框:改前/改后各一容器且单行预览', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(
                status: 'completed',
                name: 'edit',
                input: {
                  'filePath': 'main.go',
                  'oldString': 'line1\nline2\nline3\nline4',
                  'newString': 'new1\nnew2\nnew3\nnew4',
                },
                output: 'edited',
              ),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      // 改前框:单行 Text 含 - 前缀(红),改后框:单行 Text 含 + 前缀(绿)
      final oldText = tester.widget<Text>(find.textContaining('- line1'));
      final newText = tester.widget<Text>(find.textContaining('+ new1'));
      expect(oldText.maxLines, 1);
      expect(newText.maxLines, 1);
      expect(oldText.overflow, TextOverflow.ellipsis);
      expect(newText.overflow, TextOverflow.ellipsis);
      // 两个框都存在(改前红 / 改后绿)
      expect(find.textContaining('- line1'), findsOneWidget);
      expect(find.textContaining('+ new1'), findsOneWidget);
    });

    testWidgets('completed output 短文本单行 + 长文本走截断', (tester) async {
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

      final outputText = tester.widget<Text>(find.text('total 100'));
      expect(outputText.maxLines, 1);
      expect(outputText.overflow, TextOverflow.ellipsis);
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
    testWidgets('webfetch 渲染纯文字行(无工具卡容器)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(status: 'completed', name: 'webfetch'),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('WebFetch'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
      // webfetch 走纯文字行,不产生灰底工具卡 Container
      expect(find.text('\u{e600}'), findsOneWidget); // iconfont explore 图标
    });

    testWidgets('webfetch 显示 url 单行截断 + 状态', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(
                status: 'completed',
                name: 'webfetch',
                input: {'url': 'https://very-long-domain.example.com/path/to/resource'},
                output: '搜索到的内容',
              ),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      expect(find.text('WebFetch'), findsOneWidget);
      expect(find.text('https://very-long-domain.example.com/path/to/resource'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
    });

    testWidgets('webfetch 点击弹抽屉展示 url/output', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeContent(
                status: 'completed',
                name: 'webfetch',
                input: {'url': 'https://example.com'},
                output: '搜索到的完整结果内容',
              ),
              ctx,
              const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('WebFetch'));
      await tester.pumpAndSettle();
      expect(find.text('搜索结果'), findsOneWidget);
      expect(find.text('搜索到的完整结果内容'), findsOneWidget);
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
      expect(find.text(IconFont.permission), findsOneWidget);
    });

    testWidgets('子审批卡 sub_session_id 与 task 不匹配时不串挂(task 元素共享聚合卡 msgId)', (tester) async {
      // 聚合卡模式下 task 卡元素 taskCardId 都是聚合卡 id(此处 messageId),
      // 另一子 agent 的审批卡 sub_session_id 不同,不应挂到本 task 下。
      final otherChildApproval = ChatMessage.fromJson({
        'id': 'perm-other-child',
        'conversation_id': 'conv-1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'permission_card',
          'data': {
            'status': 'pending',
            'action': 'bash',
            'sub_session_id': 'ses-child-2',
          },
        },
        'parent_msg_id': 'task-msg-1',
        'created_at': '2026-07-15T10:00:00Z',
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.toolCard,
              makeTaskContent(status: 'working', subSessionId: 'ses-child-1'),
              ctx,
              MessageRenderContext(
                isMe: false, baseUrl: '', token: '', isDark: false,
                convId: 'conv-1',
                messageId: 'task-msg-1',
                conversationMessages: [otherChildApproval],
              ),
            ),
          ),
        ),
      ));

      expect(find.textContaining('待审批'), findsNothing);
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
