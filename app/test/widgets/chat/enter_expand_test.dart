import 'package:app/widgets/chat/enter_expand.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 新消息入场淡入动画:首次 build 视觉淡入,布局高度恒为完整高度。
/// 卡片/reasoning 实时新消息传 animate=true;历史加载/流式终态替换传 false
/// 直接显示完整内容(不重播动画)。
/// 不做真高度展开(SizeTransition):保证 SliverList 懒加载重建时布局高度
/// 恒定,不会因动画初期内容不足触发 ranOut → viewport correctBy 硬拉回 px。
void main() {
  testWidgets('animate=true: 高度恒定,透明度从 0 淡入到 1', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EnterExpand(
          animate: true,
          child: SizedBox(key: ValueKey('probe'), height: 100, width: 100),
        ),
      ),
    ));
    final probe = tester.getSize(find.byKey(const ValueKey('probe')));
    // 布局高度恒为 child 完整高度,动画全程不参与布局。
    expect(probe.height, 100, reason: '动画全程布局高度应恒为完整高度');
    final fade = tester.widget<FadeTransition>(
      find.descendant(
        of: find.byType(EnterExpand),
        matching: find.byType(FadeTransition),
      ),
    );
    expect(fade.opacity.value, 0, reason: '动画启动瞬间透明度应为 0');

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final midOpacity = fade.opacity.value;
    debugPrint('[probe] midOpacity=$midOpacity');
    expect(midOpacity, greaterThan(0), reason: '动画中应高于起始透明度');
    expect(midOpacity, lessThan(1), reason: '动画中应低于目标透明度(平滑过渡)');
    // 高度依旧恒定。
    expect(tester.getSize(find.byKey(const ValueKey('probe'))).height, 100);

    await tester.pumpAndSettle();
    expect(fade.opacity.value, 1, reason: '动画结束透明度到达完整');
  });

  testWidgets('animate=false: 直接显示完整高度,不播动画', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: EnterExpand(
          animate: false,
          child: SizedBox(key: ValueKey('probe'), height: 100, width: 100),
        ),
      ),
    ));
    expect(tester.getSize(find.byKey(const ValueKey('probe'))).height, 100);
  });
}
