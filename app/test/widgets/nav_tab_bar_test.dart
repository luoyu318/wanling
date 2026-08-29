// NavTabBar 纯 widget 测试:slots 渲染矩阵/角标/更多槽/点击与长按回调(无拖拽)。
import 'package:app/widgets/nav_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

NavAgentTab _tab(String id, {int unread = 0, bool online = true}) =>
    NavAgentTab(id: id, name: 'n-$id', online: online, unread: unread);

List<NavSlot> _slots({List<NavAgentTab> agents = const []}) => [
      const NavIconSlot(
          tabId: 'msg',
          label: '消息',
          icon: Icons.chat_bubble_outline,
          activeIcon: Icons.chat_bubble,
          badge: 0),
      const NavIconSlot(
          tabId: 'wanling',
          label: '万灵',
          icon: Icons.auto_awesome_outlined,
          activeIcon: Icons.auto_awesome),
      for (final t in agents) NavAgentSlot(tabId: t.id, tab: t),
    ];

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(bottomNavigationBar: child),
    );

void main() {
  testWidgets('无 agent:只渲染消息/万灵两槽', (tester) async {
    await tester.pumpWidget(_wrap(NavTabBar(
      slots: _slots(),
      currentIndex: 0,
      showMore: false,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onSlotLongPress: (_) {},
    )));
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('万灵'), findsOneWidget);
    expect(find.text('更多'), findsNothing);
  });

  testWidgets('消息槽角标渲染', (tester) async {
    await tester.pumpWidget(_wrap(NavTabBar(
      slots: const [
        NavIconSlot(
            tabId: 'msg',
            label: '消息',
            icon: Icons.chat_bubble_outline,
            activeIcon: Icons.chat_bubble,
            badge: 3),
        NavIconSlot(
            tabId: 'wanling',
            label: '万灵',
            icon: Icons.auto_awesome_outlined,
            activeIcon: Icons.auto_awesome),
      ],
      currentIndex: 0,
      showMore: false,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onSlotLongPress: (_) {},
    )));
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('agent 槽平铺:名字与未读角标', (tester) async {
    await tester.pumpWidget(_wrap(NavTabBar(
      slots: _slots(agents: [_tab('a1', unread: 2), _tab('a2'), _tab('a3')]),
      currentIndex: 2,
      showMore: false,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onSlotLongPress: (_) {},
    )));
    expect(find.text('n-a1'), findsOneWidget);
    expect(find.text('n-a2'), findsOneWidget);
    expect(find.text('n-a3'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('showMore:更多格显示 agent 名(激活)或「更多」', (tester) async {
    await tester.pumpWidget(_wrap(NavTabBar(
      slots: _slots(agents: [_tab('a1'), _tab('a2')]),
      currentIndex: 0,
      showMore: true,
      moreTab: _tab('a3'),
      onSlotTap: (_) {},
      onMoreTap: () {},
      onSlotLongPress: (_) {},
    )));
    expect(find.text('更多'), findsNothing);
    expect(find.text('n-a3'), findsOneWidget);

    await tester.pumpWidget(_wrap(NavTabBar(
      slots: _slots(agents: [_tab('a1'), _tab('a2')]),
      currentIndex: 0,
      showMore: true,
      moreTab: null,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onSlotLongPress: (_) {},
    )));
    expect(find.text('更多'), findsOneWidget);
  });

  testWidgets('点槽回调槽位号,点更多回调 onMoreTap', (tester) async {
    var tappedSlot = -1;
    var moreTapped = false;
    await tester.pumpWidget(_wrap(NavTabBar(
      slots: _slots(agents: [_tab('a1'), _tab('a2')]),
      currentIndex: 0,
      showMore: true,
      onSlotTap: (s) => tappedSlot = s,
      onMoreTap: () => moreTapped = true,
      onSlotLongPress: (_) {},
    )));
    await tester.tap(find.text('n-a1'));
    expect(tappedSlot, 2);
    await tester.tap(find.text('更多'));
    expect(moreTapped, isTrue);
  });

  testWidgets('长按槽回调 onSlotLongPress', (tester) async {
    var longPressedSlot = -1;
    await tester.pumpWidget(_wrap(NavTabBar(
      slots: _slots(agents: [_tab('a1')]),
      currentIndex: 0,
      showMore: false,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onSlotLongPress: (s) => longPressedSlot = s,
    )));
    await tester.longPress(find.text('n-a1'));
    expect(longPressedSlot, 2);
  });
}
