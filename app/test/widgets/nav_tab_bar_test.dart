// NavTabBar 纯 widget 测试:槽位渲染矩阵/角标/更多槽/长按拖拽回调。
import 'package:app/widgets/nav_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 名字 ≤5 字符,避免触发组件的 5 字符截断(brief 原值 name-$id 为 6-7 字符会被截成 name-…)
NavAgentTab _tab(String id, {int unread = 0, bool online = true}) =>
    NavAgentTab(id: id, name: 'n-$id', online: online, unread: unread);

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(
      bottomNavigationBar: child,
    ));

void main() {
  testWidgets('无 agent:只渲染消息/万灵两槽', (tester) async {
    await tester.pumpWidget(_wrap(NavTabBar(
      currentIndex: 0,
      totalUnread: 3,
      agentTabs: const [],
      showMore: false,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onAgentReorder: (_, _) {},
    )));
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('万灵'), findsOneWidget);
    expect(find.text('更多'), findsNothing);
    // 消息角标
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('agentTabs 3 个以内平铺,每个槽显示名字与角标', (tester) async {
    await tester.pumpWidget(_wrap(NavTabBar(
      currentIndex: 2,
      totalUnread: 0,
      agentTabs: [_tab('a1', unread: 2), _tab('a2'), _tab('a3')],
      showMore: false,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onAgentReorder: (_, _) {},
    )));
    expect(find.text('n-a1'), findsOneWidget);
    expect(find.text('n-a2'), findsOneWidget);
    expect(find.text('n-a3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // a1 角标
  });

  testWidgets('showMore:更多槽出现,moreTab 激活时显示其名字', (tester) async {
    await tester.pumpWidget(_wrap(NavTabBar(
      currentIndex: 4,
      totalUnread: 0,
      agentTabs: [_tab('a1'), _tab('a2')],
      showMore: true,
      moreTab: _tab('a3'),
      onSlotTap: (_) {},
      onMoreTap: () {},
      onAgentReorder: (_, _) {},
    )));
    expect(find.text('更多'), findsNothing); // 激活态显示 agent 名
    expect(find.text('n-a3'), findsOneWidget);

    await tester.pumpWidget(_wrap(NavTabBar(
      currentIndex: 0,
      totalUnread: 0,
      agentTabs: [_tab('a1'), _tab('a2')],
      showMore: true,
      moreTab: null,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onAgentReorder: (_, _) {},
    )));
    expect(find.text('更多'), findsOneWidget);
  });

  testWidgets('点更多槽回调 onMoreTap', (tester) async {
    var moreTapped = false;
    await tester.pumpWidget(_wrap(NavTabBar(
      currentIndex: 0,
      totalUnread: 0,
      agentTabs: [_tab('a1'), _tab('a2')],
      showMore: true,
      onSlotTap: (_) {},
      onMoreTap: () => moreTapped = true,
      onAgentReorder: (_, _) {},
    )));
    await tester.tap(find.text('更多'));
    expect(moreTapped, isTrue);
  });

  testWidgets('长按拖拽 agent 槽到另一 agent 槽触发 onAgentReorder',
      (tester) async {
    final reorderCalls = <String>[];
    await tester.pumpWidget(_wrap(NavTabBar(
      currentIndex: 0,
      totalUnread: 0,
      agentTabs: [_tab('a1'), _tab('a2')],
      showMore: false,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onAgentReorder: (id, slot) => reorderCalls.add('$id->$slot'),
    )));
    // 长按 a1 槽并拖到 a2 槽中心
    final a1Center = tester.getCenter(find.text('n-a1'));
    final a2Center = tester.getCenter(find.text('n-a2'));
    final gesture = await tester.startGesture(a1Center);
    await tester.pump(const Duration(seconds: 1)); // LongPressGrad 触发
    await gesture.moveBy(a2Center - a1Center);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(reorderCalls, ['a1->1']);
  });
}
