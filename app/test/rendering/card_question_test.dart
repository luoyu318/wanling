import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/card_renderer.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/widgets/card_button.dart';

/// question 审批卡（card_type=question）渲染测试。
/// - pending：选项列表（单选 radio / 多选 checkbox）+ 提交答案/拒绝按钮
/// - 提交 → onDecide(approvalId, 'answer', answers: 选中 id 列表)
/// - 终态：answers 摘要（id 映射 label 后 join('、')）
///
/// 注意:pending 卡含 CountdownTimer(周期 Timer),断言用 pump(Duration) 而非
/// pumpAndSettle,避免永不 settle 超时(对齐 card_renderer_dark_test)。
void main() {
  setUpAll(registerBuiltinRenderers);

  // onDecide 是 static 回调,测试内注入捕获器,结束后清掉防串扰
  String? capturedApprovalId;
  String? capturedActionId;
  List<String>? capturedAnswers;
  setUp(() {
    capturedApprovalId = null;
    capturedActionId = null;
    capturedAnswers = null;
    CardContentRenderer.onDecide =
        (approvalId, actionId, reason, answers) async {
      capturedApprovalId = approvalId;
      capturedActionId = actionId;
      capturedAnswers = answers;
      return null;
    };
  });
  tearDown(() => CardContentRenderer.onDecide = null);

  Map<String, dynamic> questionContent({
    required bool multiSelect,
    String state = 'pending',
    String? decidedAction,
    List<String>? answers,
  }) {
    return {
      'msg_type': 'card',
      'data': {
        'approval_id': 'q-approval-1',
        'card_type': 'question',
        'title': '选择部署环境',
        'state': state,
        'decided_action': ?decidedAction,
        'answers': ?answers,
        'options': [
          {'id': 'dev', 'label': '开发环境'},
          {'id': 'staging', 'label': '预发环境'},
        ],
        'multi_select': multiSelect,
        'actions': [
          {'id': 'answer', 'label': '提交答案', 'icon': 'check', 'style': 'primary'},
          {'id': 'reject', 'label': '拒绝', 'icon': 'x', 'style': 'danger'},
        ],
        'expires_at': DateTime.now()
            .add(const Duration(hours: 1))
            .toUtc()
            .toIso8601String(),
      },
    };
  }

  Widget host(Map<String, dynamic> content) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.card,
            content,
            ctx,
            const MessageRenderContext(isMe: false, baseUrl: '', token: '', isDark: false),
          ),
        ),
      ),
    );
  }

  testWidgets('question 单选作答提交 answers', (tester) async {
    await tester.pumpWidget(host(questionContent(multiSelect: false)));
    await tester.pump(const Duration(milliseconds: 100));

    // 选项均已渲染
    expect(find.text('开发环境'), findsOneWidget);
    expect(find.text('预发环境'), findsOneWidget);

    // 未选任何选项时「提交答案」置灰
    final submit = tester.widget<CardButton>(
      find.ancestor(of: find.text('提交答案'), matching: find.byType(CardButton)),
    );
    expect(submit.state, CardButtonState.disabled);

    // 单选点击即选:先点 dev 再点 staging,最终仅 staging 选中
    await tester.tap(find.text('开发环境'));
    await tester.pump();
    await tester.tap(find.text('预发环境'));
    await tester.pump();

    await tester.tap(find.text('提交答案'));
    await tester.pump();

    expect(capturedApprovalId, 'q-approval-1');
    expect(capturedActionId, 'answer');
    expect(capturedAnswers, ['staging']);
  });

  testWidgets('question 多选可勾选多项', (tester) async {
    await tester
        .pumpWidget(host(questionContent(multiSelect: true)));
    await tester.pump(const Duration(milliseconds: 100));

    // 多选 toggle:两项都勾上(点选顺序与 options 顺序相反,验证提交按 options 顺序)
    await tester.tap(find.text('预发环境'));
    await tester.pump();
    await tester.tap(find.text('开发环境'));
    await tester.pump();

    await tester.tap(find.text('提交答案'));
    await tester.pump();

    expect(capturedActionId, 'answer');
    expect(capturedAnswers, ['dev', 'staging']);
  });

  testWidgets('question 终态回显 answers 摘要', (tester) async {
    await tester.pumpWidget(host(questionContent(
      multiSelect: true,
      state: 'approved',
      decidedAction: 'answer',
      answers: ['dev', 'staging'],
    )));
    await tester.pump(const Duration(milliseconds: 100));

    // answers 是选项 id,回显映射为 label 后 join('、')
    expect(find.textContaining('开发环境、预发环境'), findsOneWidget);
    // 终态徽章 + 按钮不可再点
    expect(find.text('✓ 已批准'), findsOneWidget);
    final submit = tester.widget<CardButton>(
      find.ancestor(of: find.text('已回答'), matching: find.byType(CardButton)),
    );
    expect(submit.state, CardButtonState.selected);
  });
}
