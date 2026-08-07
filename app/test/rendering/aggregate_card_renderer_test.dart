import 'package:app/models/msg_type.dart';
import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/rendering/message_content_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> questionCardData({String status = 'pending'}) {
  return {
    'status': status,
    'oc_request_id': 'req-1',
    if (status == 'answered') 'result': 'main',
    'questions': [
      {
        'header': '选择分支',
        'question': '用哪个分支?',
        'options': [
          {'label': 'main', 'description': ''},
          {'label': 'dev', 'description': ''},
        ],
        'multiple': false,
        'custom': false,
      },
    ],
  };
}

Map<String, dynamic> permissionCardData({String status = 'pending'}) {
  return {
    'status': status,
    'oc_request_id': 'req-1',
    'action': 'bash',
    'resources': ['/tmp'],
    'metadata': {'command': 'ls'},
    'save': ['/tmp/*'],
    if (status == 'approved') 'result': 'always',
  };
}

/// 捕获子 renderer 收到的 MessageRenderContext（验证 isStreaming 派生）。
class _CapturingRenderer implements MessageContentRenderer {
  final void Function(MessageRenderContext) onBuild;
  const _CapturingRenderer(this.onBuild);

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    onBuild(rc);
    return const SizedBox.shrink();
  }
}

void main() {
  setUp(() {
    ContentRendererRegistry.reset();
    registerBuiltinRenderers();
  });

  Map<String, dynamic> element(String type, String id, Map<String, dynamic> data) {
    return {
      'type': type,
      'element_id': id,
      'data': data,
    };
  }

  Map<String, dynamic> content({
    String state = 'generating',
    List<Map<String, dynamic>> elements = const [],
  }) {
    return {
      'msg_type': MsgType.aggregateCard.value,
      'data': {'state': state, 'elements': elements},
    };
  }

  Widget host(Map<String, dynamic> c, {String outerMessageId = ''}) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.aggregateCard,
            c,
            ctx,
            MessageRenderContext(
              isMe: false,
              baseUrl: 'http://localhost',
              token: 'test',
              isDark: false,
              messageId: outerMessageId,
            ),
          ),
        ),
      ),
    );
  }

  group('顶栏去除', () {
    testWidgets('generating 不渲染「回复中」顶栏文案', (tester) async {
      await tester.pumpWidget(host(content(state: 'generating')));
      expect(find.text('回复中'), findsNothing);
      expect(find.text('完成'), findsNothing);
    });

    testWidgets('done 不渲染「完成」顶栏文案', (tester) async {
      await tester.pumpWidget(host(content(state: 'done')));
      expect(find.text('完成'), findsNothing);
      expect(find.text('回复中'), findsNothing);
    });
  });

  group('元素分派（复用 ContentRendererRegistry）', () {
    testWidgets('markdown 元素渲染正文', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('markdown', 'markdown_1', {'text': '最终回复正文'}),
        ],
      )));
      expect(find.text('最终回复正文'), findsOneWidget);
    });

    testWidgets('markdown 元素 generating 时正文仍渲染（流式分支）', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'generating',
        elements: [
          element('markdown', 'markdown_1', {'text': '正在输出的正文'}),
        ],
      )));
      expect(find.text('正在输出的正文'), findsOneWidget);
    });

    testWidgets('reasoning 元素渲染思考折叠摘要（Thought 文案）', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('reasoning', 'reasoning_1', {'text': '分析需求并设计方案'}),
        ],
      )));
      // 折叠态显示 Thought(对齐 TUI),不展示全文首行
      expect(find.text('Thought'), findsOneWidget);
      expect(find.text('分析需求并设计方案'), findsNothing);
    });

    testWidgets('reasoning 元素带 duration → 折叠显示 Thought: X.Xs', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('reasoning', 'reasoning_1', {'text': '思考', 'duration': 3500}),
        ],
      )));
      expect(find.text('Thought: 3.5s'), findsOneWidget);
    });

    testWidgets('tool_card 元素折叠为「工具调用 · 1」,点击展开显示工具列表项', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('tool_card', 'tool_card_1', {
            'name': 'bash',
            'status': 'error',
            'input': {'command': 'ls'},
            'error': '命令失败',
          }),
        ],
      )));
      // 收起态:折叠行,不显示工具详情
      expect(find.text('工具调用 · 1'), findsOneWidget);
      expect(find.text('Bash'), findsNothing);
      // 点击展开后显示工具卡详情
      await tester.tap(find.text('工具调用 · 1'));
      await tester.pump();
      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('命令失败'), findsOneWidget);
    });

    testWidgets('compact_divider 元素渲染分隔线', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('compact_divider', 'divider_1', const {}),
        ],
      )));
      expect(find.byType(Divider), findsNothing);
      // 压缩分隔用自绘细线(Container color → ColoredBox 1px #EEEEEE,
      // 不引入 Divider 默认缩进/上下间距)
      expect(
        tester
            .widgetList<ColoredBox>(find.byType(ColoredBox))
            .any((c) => c.color == const Color(0xFFEEEEEE)),
        isTrue,
      );
    });

    testWidgets('footer 元素渲染底部信息行（耗时/tokens）', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('footer', 'footer_1', {
            'duration': 12.3,
            'tokens': {'total': 2100},
          }),
        ],
      )));
      expect(find.text('⏱ 12.3s'), findsOneWidget);
      expect(find.text('tokens 2.1k'), findsOneWidget);
    });
  });

  group('元素 data 结构对齐', () {
    testWidgets('tool_card 元素 data 对齐现有 tool_card renderer 消费字段', (tester) async {
      // ToolCardRenderer 读 data.status 决定三态,此处 completed + output 走完成卡
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('tool_card', 'tool_card_1', {
            'name': 'read',
            'status': 'completed',
            'input': {'path': 'lib/main.dart'},
            'output': '<path>lib/main.dart</path>\n<type>file</type>\n<content>\n1: void main()\n</content>',
          }),
        ],
      )));
      // 收起态先展开
      await tester.tap(find.text('工具调用 · 1'));
      await tester.pump();
      expect(find.text('Read'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget); // 仅工具卡状态(顶栏已去除)
    });

    testWidgets('footer 元素 data 对齐 step_finish renderer（cost 字段）', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('footer', 'footer_1', {
            'duration': 1.5,
            'cost': 0.123,
            'tokens': {'total': 800},
          }),
        ],
      )));
      expect(find.text('⏱ 1.5s'), findsOneWidget);
      expect(find.text(r'$0.123'), findsOneWidget);
      expect(find.text('tokens 0.8k'), findsOneWidget);
    });
  });

  group('question_card / permission_card 交互元素', () {
    testWidgets('question_card 元素渲染 pending 选择题卡', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('question_card', 'question_card_1', questionCardData()),
        ],
      )));
      expect(find.text('选择题'), findsOneWidget);
      expect(find.text('选择分支'), findsOneWidget);
      expect(find.text('点击回答 →'), findsOneWidget);
    });

    testWidgets('question_card 元素点击弹选择题抽屉', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('question_card', 'question_card_1', questionCardData()),
        ],
      )));
      await tester.tap(find.text('点击回答 →'));
      await tester.pumpAndSettle();
      // 题干只在抽屉内出现
      expect(find.text('用哪个分支?'), findsOneWidget);
    });

    testWidgets('permission_card 元素渲染 pending 审批卡', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('permission_card', 'permission_card_1', permissionCardData()),
        ],
      )));
      expect(find.text('权限审批 · 执行命令'), findsOneWidget);
      expect(find.text('ls'), findsOneWidget);
      expect(find.text('点击处理 →'), findsOneWidget);
    });

    testWidgets('permission_card 元素点击弹权限审批抽屉', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('permission_card', 'permission_card_1', permissionCardData()),
        ],
      )));
      await tester.tap(find.text('点击处理 →'));
      await tester.pumpAndSettle();
      // 抽屉头部「权限审批」+ 动作「执行命令」可见
      expect(find.text('权限审批'), findsOneWidget);
      expect(find.text('执行命令'), findsOneWidget);
    });

    testWidgets('question_card 元素终态(answered)渲染结果摘要,不可操作', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('question_card', 'question_card_1',
              questionCardData(status: 'answered')),
        ],
      )));
      expect(find.textContaining('已回答'), findsOneWidget);
      expect(find.text('点击回答 →'), findsNothing);
    });

    testWidgets('permission_card 元素终态(approved)渲染结果摘要,不可操作', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('permission_card', 'permission_card_1',
              permissionCardData(status: 'approved')),
        ],
      )));
      expect(find.text('已批准（始终）'), findsOneWidget);
      expect(find.text('点击处理 →'), findsNothing);
    });

    testWidgets('交互元素不派生 isStreaming（generating 期间仍可交互）', (tester) async {
      bool? captured;
      ContentRendererRegistry.register(
        MsgType.questionCard,
        _CapturingRenderer((rc) => captured = rc.isStreaming),
      );
      await tester.pumpWidget(host(content(
        state: 'generating',
        elements: [
          element('question_card', 'question_card_1', questionCardData()),
        ],
      )));
      expect(captured, isFalse);
    });
  });

  group('内嵌元素 rc 注入（rootMessageId）', () {
    testWidgets('tool_card 元素 rc.messageId = element_id, rc.rootMessageId = 聚合卡真实消息 id',
        (tester) async {
      MessageRenderContext? captured;
      ContentRendererRegistry.register(
        MsgType.toolCard,
        _CapturingRenderer((rc) => captured = rc),
      );
      await tester.pumpWidget(host(
        content(
          state: 'done',
          elements: [
            element('tool_card', 'tool_card_5', {
              'name': 'task',
              'status': 'completed',
              'input': {'description': '调研', 'subagent_type': 'general'},
              'sub_session_id': 'ses-child-1',
            }),
          ],
        ),
        outerMessageId: 'agg-msg-real-1',
      ));

      expect(captured, isNotNull);
      expect(captured!.messageId, 'tool_card_5');
      expect(captured!.rootMessageId, 'agg-msg-real-1');
    });
  });

  group('工具卡折叠 + 底部提示条', () {
    testWidgets('连续 tool_card 折叠成一组(收起态显示 ⚡ 工具调用 · 2)', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('tool_card', 'tool_card_1', {'name': 'bash', 'status': 'completed', 'input': {'command': 'ls'}}),
          element('tool_card', 'tool_card_2', {'name': 'read', 'status': 'completed', 'input': {'path': 'x.dart'}}),
        ],
      )));
      expect(find.text('工具调用 · 2'), findsOneWidget);
      // 收起态不展开工具详情
      expect(find.text('Bash'), findsNothing);
    });

    testWidgets('点击折叠卡展开显示工具卡详情', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('tool_card', 'tool_card_1', {'name': 'bash', 'status': 'error', 'input': {'command': 'ls'}, 'error': '命令失败'}),
        ],
      )));
      await tester.tap(find.text('工具调用 · 1'));
      await tester.pump();
      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('命令失败'), findsOneWidget);
    });

    testWidgets('state=done + finished footer → 渲染底部提示条', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('footer', 'footer_1', {
            'finished': true,
            'mode': 'build',
            'model': 'DeepSeek-V3',
            'duration': 12300,
            'tokens': {'total': 2100},
          }),
        ],
      )));
      expect(find.text('build'), findsOneWidget);
      expect(find.text('12.3s'), findsOneWidget);
      expect(find.text('DeepSeek-V3'), findsOneWidget);
      expect(find.text('tokens 2.1k'), findsOneWidget);
    });

    testWidgets('state=generating → footer 显示动态阶段词(不显示静态信息)', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'generating',
        elements: [
          element('tool_card', 'tool_card_1', {'name': 'bash', 'status': 'running', 'input': {'command': 'ls'}}),
          element('footer', 'footer_1', {'finished': true, 'mode': 'build', 'model': 'M', 'duration': 1, 'tokens': {'total': 100}}),
        ],
      )));
      // 动态阶段词(最后元素 tool_card → 执行中)
      expect(find.text('执'), findsOneWidget);
      // 静态信息条不渲染
      expect(find.text('build'), findsNothing);
    });

    testWidgets('task 子 agent 卡不折叠(平铺可点击)', (tester) async {
      await tester.pumpWidget(host(content(
        state: 'done',
        elements: [
          element('tool_card', 'tool_card_1', {'name': 'task', 'status': 'completed', 'input': {'description': '调研'}, 'sub_session_id': 's1'}),
        ],
      )));
      expect(find.text('工具调用 · 1'), findsNothing);
      expect(find.text('调研'), findsOneWidget);
    });
  });

  group('空守卫', () {
    testWidgets('无 elements 时渲染空卡片(无顶栏文案)', (tester) async {
      await tester.pumpWidget(host(content(state: 'generating')));
      expect(find.text('回复中'), findsNothing);
      expect(find.text('完成'), findsNothing);
    });
  });
}
