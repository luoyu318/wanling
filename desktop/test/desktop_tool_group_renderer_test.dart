import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
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

  testWidgets('思考块:hover 时前导 icon 切换,无尾部 ▸', (tester) async {
    await tester.pumpWidget(host(DesktopReasoningCard(
      text: '思考内容',
      duration: 2,
    )));
    expect(find.text('▸'), findsNothing);
    await hover(tester, find.textContaining('思考完成'));
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });
}
