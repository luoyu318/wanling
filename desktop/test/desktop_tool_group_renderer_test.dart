import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_desktop/rendering/desktop_permission_card_renderer.dart';
import 'package:wanling_desktop/rendering/desktop_reasoning_renderer.dart';
import 'package:wanling_desktop/rendering/desktop_tool_group_renderer.dart';

/// 桌面版折叠组/思考块 hover 交互:
/// - 折叠组:去尾部展开箭头,hover 时前导类别 icon 切换成 ▸/▾ 展开指示;
/// - 思考块:去尾部 ▸,hover 时前导 icon 同步切换。
/// 非 hover 时恢复类别/思考 icon,保持静态视觉干净。
void main() {
  Widget host(Widget child) {
    return MaterialApp(
      home: Scaffold(
        body: Center(child: child),
      ),
    );
  }

  Future<void> hover(WidgetTester tester, Finder finder) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(finder));
    addTearDown(gesture.removePointer);
    await tester.pumpAndSettle();
  }

  testWidgets('折叠组:默认前导类别 icon,无尾部箭头', (tester) async {
    final cards = [
      {
        'type': 'tool_card',
        'element_id': 't1',
        'data': {'name': 'read', 'status': 'done'},
      },
      {
        'type': 'tool_card',
        'element_id': 't2',
        'data': {'name': 'grep', 'status': 'done'},
      },
    ];
    await tester.pumpWidget(host(DesktopToolGroupCard(
      cards: cards,
      rc: const MessageRenderContext(
        isMe: false,
        baseUrl: '',
        token: '',
        isDark: false,
        messageId: 'm1',
      ),
    )));
    // 默认(非 hover):无展开/收起箭头(Material expand icon)。
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.byIcon(Icons.expand_less), findsNothing);
  });

  testWidgets('折叠组:hover 时前导 icon 切换为展开指示', (tester) async {
    final cards = [
      {
        'type': 'tool_card',
        'element_id': 't1',
        'data': {'name': 'read', 'status': 'done'},
      },
    ];
    await tester.pumpWidget(host(DesktopToolGroupCard(
      cards: cards,
      rc: const MessageRenderContext(
        isMe: false,
        baseUrl: '',
        token: '',
        isDark: false,
        messageId: 'm1',
      ),
    )));
    // hover 标题行:前导 icon 变为「展开」箭头(chevron_right,未展开态)。
    await hover(tester, find.textContaining('已探索'));
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    // 点击展开后再 hover:变为「收起」箭头(expand_less 方向)。
    await tester.tap(find.textContaining('已探索'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
  });

  testWidgets('思考块:hover 时前导 icon 切换,点击卡内原地展开', (tester) async {
    await tester.pumpWidget(host(DesktopReasoningCard(
      text: '思考内容',
      duration: 2,
    )));
    expect(find.text('▸'), findsNothing);
    await hover(tester, find.textContaining('思考完成'));
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    // 点击:原地展开显示 markdown 全文(无底部抽屉)。
    await tester.tap(find.textContaining('思考完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('思考内容'), findsWidgets);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('权限卡终态:hover 切前导 icon,点击原地展开原卡', (tester) async {
    const rc = MessageRenderContext(
      isMe: false,
      baseUrl: '',
      token: '',
      isDark: false,
      messageId: 'm1',
    );
    final content = <String, dynamic>{
      'msg_type': 'permission_card',
      'data': {
        'status': 'approved',
        'action': 'bash',
        'result': 'once',
        'resources': ['rm -rf /tmp/x'],
        'metadata': <String, dynamic>{},
        'oc_request_id': 'r1',
      },
    };
    await tester.pumpWidget(host(Builder(
      builder: (ctx) =>
          const DesktopPermissionCardRenderer().build(ctx, content, rc),
    )));
    // 折叠态:标题行结果可见(展开内容 heightFactor 0 裁剪,只 1 个可点)。
    expect(find.textContaining('已批准').hitTestable(), findsOneWidget);
    // 无尾部常驻箭头。
    expect(find.byIcon(Icons.expand_more), findsNothing);
    // hover:前导 icon 切 chevron(标题行与展开内容同名文本,取可点的首个)。
    await hover(tester, find.textContaining('权限审批').hitTestable().first);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    // 点击:展开原卡(命令明细可见)。
    await tester.tap(find.textContaining('权限审批').hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('rm -rf /tmp/x').hitTestable(), findsOneWidget);
  });
}
