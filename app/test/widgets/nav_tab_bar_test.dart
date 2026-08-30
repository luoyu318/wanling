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

  testWidgets('会话槽:渲染名字/未读角标,点按与长按回调槽位号', (tester) async {
    var tapped = -1;
    var longPressed = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: NavTabBar(
          slots: const [
            NavIconSlot(
                tabId: 'msg',
                label: '消息',
                icon: Icons.chat_bubble_outline,
                activeIcon: Icons.chat_bubble),
            NavConvSlot(
                tabId: 'conv:c1',
                tab: NavConvTab(id: 'c1', name: '项目群', unread: 5)),
          ],
          currentIndex: -1,
          showMore: false,
          onSlotTap: (i) => tapped = i,
          onMoreTap: () {},
          onSlotLongPress: (i) => longPressed = i,
        ),
      ),
    ));
    expect(find.text('项目群'), findsOneWidget);
    expect(find.text('5'), findsOneWidget); // 未读角标
    await tester.tap(find.text('项目群'));
    expect(tapped, 1);
    await tester.longPress(find.text('项目群'));
    expect(longPressed, 1);
  });

  testWidgets('在线绿点只出现在 agent 槽,会话槽无绿点', (tester) async {
    await tester.pumpWidget(_wrap(NavTabBar(
      slots: const [
        NavAgentSlot(
            tabId: 'a1',
            tab: NavAgentTab(id: 'a1', name: 'n-a1', online: true)),
        NavConvSlot(
            tabId: 'conv:c1', tab: NavConvTab(id: 'c1', name: '项目群')),
      ],
      currentIndex: -1,
      showMore: false,
      onSlotTap: (_) {},
      onMoreTap: () {},
      onSlotLongPress: (_) {},
    )));
    const dot = ValueKey('nav-online-dot');
    // 渲染 widget(_AgentSlot/_ConvSlot)为私有类,改按槽位下标定位:
    // Row 内每槽一个 Expanded,位 0 = agent 槽,位 1 = conv 槽。
    final slotsFinder = find.descendant(
        of: find.byType(NavTabBar), matching: find.byType(Expanded));
    // agent 槽(位 0)范围内恰一个绿点
    expect(
      find.descendant(of: slotsFinder.at(0), matching: find.byKey(dot)),
      findsOneWidget,
    );
    // 会话槽(位 1)范围内不允许出现绿点(会话无在线概念)
    expect(
      find.descendant(of: slotsFinder.at(1), matching: find.byKey(dot)),
      findsNothing,
    );
  });
}
