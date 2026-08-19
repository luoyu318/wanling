import 'package:wanling_core/models/agent.dart';
import 'package:app/utils/directory_utils.dart';
import 'package:app/widgets/avatar.dart';
import 'package:app/widgets/directory_panel.dart';
import 'package:app/widgets/directory_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dirs = [
    const DirectoryInfo(path: '/proj/src', sessionCount: 3, unreadCount: 2),
    const DirectoryInfo(path: '/proj/docs', sessionCount: 1, unreadCount: 0),
  ];

  final testAgent = AgentSummary(
    id: 'agent-1',
    name: 'Wanling',
    status: AgentStatus.online,
  );

  Widget buildFrame({
    AgentSummary? agent,
    List<DirectoryInfo> directories = const [],
    String? selectedPath,
    bool showHeader = false,
    void Function(String?)? onSelected,
    void Function(int, int)? onReorder,
    VoidCallback? onNewSession,
  }) {
    return ProviderScope(
      overrides: const [],
      child: MaterialApp(
        home: Scaffold(
          body: DirectoryPanel(
            agent: agent,
            directories: directories,
            selectedPath: selectedPath,
            showHeader: showHeader,
            onSelected: onSelected ?? (_) {},
            onReorder: onReorder ?? (_, _) {},
            onNewSession: onNewSession ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('renders directory list', (tester) async {
    await tester.pumpWidget(buildFrame(directories: dirs));
    expect(find.text('/proj/src'), findsOneWidget);
    expect(find.text('/proj/docs'), findsOneWidget);
  });

  testWidgets('shows header when showHeader is true', (tester) async {
    await tester.pumpWidget(buildFrame(directories: dirs, showHeader: true));
    expect(find.text('目录'), findsOneWidget);
  });

  testWidgets('highlights selected directory', (tester) async {
    await tester.pumpWidget(
        buildFrame(directories: dirs, selectedPath: '/proj/src'));
    expect(find.text('/proj/src'), findsWidgets);
    // 清理 Marquee 无限动画(选中态触发)
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });

  testWidgets('bottom new session button exists', (tester) async {
    await tester.pumpWidget(buildFrame(directories: dirs));
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('calls onNewSession when bottom button tapped', (tester) async {
    var called = false;
    await tester.pumpWidget(buildFrame(
      directories: dirs,
      onNewSession: () => called = true,
    ));
    await tester.tap(find.byIcon(Icons.add));
    expect(called, isTrue);
  });

  testWidgets(
      'whole tile wrapped by delayed drag listener for long-press reorder',
      (tester) async {
    await tester.pumpWidget(buildFrame(directories: dirs));
    expect(find.text('⋮⋮'), findsNothing);
    expect(find.byType(ReorderableDelayedDragStartListener), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byType(ReorderableDelayedDragStartListener),
        matching: find.byType(DirectoryTile),
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('header shows agent avatar with size 52 when agent provided',
      (tester) async {
    await tester.pumpWidget(buildFrame(agent: testAgent, directories: dirs));
    expect(find.byType(Avatar), findsOneWidget);
    final avatar = tester.widget<Avatar>(find.byType(Avatar));
    expect(avatar.size, 52);
    expect(avatar.name, 'Wanling');
  });

  testWidgets('header shows bio when agent.bio provided', (tester) async {
    final agentWithBio = AgentSummary(
      id: 'agent-1',
      name: 'Wanling',
      status: AgentStatus.online,
      bio: '我的个人简介',
    );
    await tester.pumpWidget(
        buildFrame(agent: agentWithBio, directories: dirs));
    expect(find.text('我的个人简介'), findsOneWidget);
    expect(find.text('工作目录'), findsNothing);
  });

  testWidgets('header hides bio when bio is null', (tester) async {
    await tester.pumpWidget(buildFrame(agent: testAgent, directories: dirs));
    expect(find.text('工作目录'), findsNothing);
  });

  testWidgets('header hides bio when bio is empty', (tester) async {
    final agentEmptyBio = AgentSummary(
      id: 'agent-1',
      name: 'Wanling',
      status: AgentStatus.online,
      bio: '',
    );
    await tester.pumpWidget(
        buildFrame(agent: agentEmptyBio, directories: dirs));
    expect(find.text('工作目录'), findsNothing);
  });
}
