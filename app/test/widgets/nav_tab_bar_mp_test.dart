// NavMpSlot 纯 widget 测试:小程序槽渲染与点按回调。
import 'package:app/widgets/nav_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('NavMpSlot 渲染名称且点按回调槽位号', (tester) async {
    var tapped = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: NavTabBar(
          currentIndex: -1,
          slots: const [
            NavMpSlot(
              tabId: 'mp:demo',
              tab: NavMpTab(id: 'demo', name: '演示应用'),
            ),
          ],
          showMore: false,
          onSlotTap: (i) => tapped = i,
          onMoreTap: () {},
          onSlotLongPress: (_) {},
        ),
      ),
    ));
    expect(find.text('演示应用'), findsOneWidget);
    await tester.tap(find.text('演示应用'));
    expect(tapped, 0);
  });
}
