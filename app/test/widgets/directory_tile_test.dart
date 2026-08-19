import 'package:wanling_core/utils/directory_utils.dart';
import 'package:app/widgets/directory_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:marquee/marquee.dart';

void main() {
  Widget buildFrame({
    required DirectoryInfo info,
    bool isSelected = false,
    VoidCallback? onTap,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: DirectoryTile(
          info: info,
          isSelected: isSelected,
          onTap: onTap ?? () {},
        ),
      ),
    );
  }

  testWidgets('renders directory path and counts', (tester) async {
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(
        path: '/proj/src',
        sessionCount: 3,
        unreadCount: 2,
      ),
    ));
    expect(find.text('/proj/src'), findsOneWidget);
    expect(find.text('3 个会话'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('shows "未归类" for null path', (tester) async {
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(path: null, sessionCount: 1, unreadCount: 0),
    ));
    expect(find.text('未归类'), findsOneWidget);
  });

  testWidgets('does not show unread badge when 0', (tester) async {
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(path: '/proj', sessionCount: 1, unreadCount: 0),
    ));
    expect(find.text('0'), findsNothing);
  });

  testWidgets('highlights when selected', (tester) async {
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(path: '/proj', sessionCount: 1, unreadCount: 0),
      isSelected: true,
    ));
    // 选中态用 Marquee 渲染 path(Marquee 内部多 Text 重复渲染)
    expect(find.byType(Marquee), findsOneWidget);
    expect(find.text('/proj'), findsWidgets);
    // 卸载 widget 让 Marquee dispose,清理 Future.doWhile + pauseAfterRound Timer
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });

  testWidgets('non-selected does NOT render Marquee', (tester) async {
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(path: '/proj', sessionCount: 1, unreadCount: 0),
    ));
    expect(find.byType(Marquee), findsNothing);
    expect(find.text('/proj'), findsOneWidget);
  });

  testWidgets('selected short name still renders Marquee widget', (tester) async {
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(path: '/a', sessionCount: 1, unreadCount: 0),
      isSelected: true,
    ));
    expect(find.byType(Marquee), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });

  testWidgets('calls onTap when tapped', (tester) async {
    var tapped = false;
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(path: '/proj', sessionCount: 1, unreadCount: 0),
      onTap: () => tapped = true,
    ));
    await tester.tap(find.text('/proj'));
    expect(tapped, isTrue);
  });

  testWidgets('pendingCount > 0 shows pending text in red', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DirectoryTile(
          info: const DirectoryInfo(
            path: '/proj',
            sessionCount: 3,
            unreadCount: 0,
            pendingCount: 2,
          ),
          isSelected: false,
          onTap: () {},
        ),
      ),
    ));

    expect(find.textContaining('待处理 2 项'), findsOneWidget);
  });

  testWidgets('pendingCount == 0 shows only session count', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DirectoryTile(
          info: const DirectoryInfo(
            path: '/proj',
            sessionCount: 3,
            unreadCount: 0,
            pendingCount: 0,
          ),
          isSelected: false,
          onTap: () {},
        ),
      ),
    ));

    expect(find.text('3 个会话'), findsOneWidget);
    expect(find.textContaining('待处理'), findsNothing);
  });

  testWidgets('busyCount > 0 显示活跃文案(绿色)', (tester) async {
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(
        path: '/proj/src',
        sessionCount: 3,
        unreadCount: 0,
        pendingCount: 0,
        busyCount: 2,
      ),
      isSelected: false,
    ));
    expect(find.text('3 个会话 · 活跃 2'), findsOneWidget);
  });

  testWidgets('pending 优先于 busy(两者都有时显 pending)', (tester) async {
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(
        path: '/proj/src',
        sessionCount: 3,
        unreadCount: 0,
        pendingCount: 1,
        busyCount: 2,
      ),
      isSelected: false,
    ));
    expect(find.text('3 个会话 · 待处理 1 项'), findsOneWidget);
    expect(find.text('3 个会话 · 活跃 2'), findsNothing);
  });

  testWidgets('busyCount=0 且 pending=0 显普通文案', (tester) async {
    await tester.pumpWidget(buildFrame(
      info: const DirectoryInfo(
        path: '/proj/src',
        sessionCount: 3,
        unreadCount: 0,
        pendingCount: 0,
        busyCount: 0,
      ),
      isSelected: false,
    ));
    expect(find.text('3 个会话'), findsOneWidget);
  });
}
