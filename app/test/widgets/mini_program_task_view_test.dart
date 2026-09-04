// 小程序卡片多任务视图 widget 测试:
// 1. 渲染每个实例一个卡片(tab 数=instances.length)
// 2. 点卡片 → onRestore(appid) 且 onCloseView 被调
// 3. 卡片上滑(Dismissible up) → onClose(appid)
// 4. 点卡片外空白 → onCloseView
// 5. 系统返回(PopScope) → onCloseView
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/widgets/mini_program_task_view.dart';

/// 回调记录器
class _Recorder {
  final restored = <String>[];
  final closed = <String>[];
  int viewClosed = 0;
}

MiniProgramInstance _inst(String appid, String name) =>
    MiniProgramInstance(appid: appid, openedAt: DateTime.now())..name = name;

/// 测试宿主:持有实例列表,close 时移除对应实例(模拟 Host 监听 manager 重建)。
/// Avatar 是 ConsumerWidget,需要 ProviderScope。
class _Host extends StatefulWidget {
  const _Host({required this.initial, required this.rec});

  final List<MiniProgramInstance> initial;
  final _Recorder rec;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late final List<MiniProgramInstance> _instances = List.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      child: MaterialApp(
        home: MiniProgramTaskView(
          instances: _instances,
          onRestore: widget.rec.restored.add,
          onClose: (appid) => setState(() {
            widget.rec.closed.add(appid);
            _instances.removeWhere((i) => i.appid == appid);
          }),
          onCloseView: () => widget.rec.viewClosed++,
        ),
      ),
    );
  }
}

void main() {
  group('taskCardLayout 布局纯函数', () {
    test('卡片按屏幕宽高比等比缩放', () {
      final layout = taskCardLayout(const Size(800, 600));
      expect(layout.cardW, closeTo(800 * 0.74, 0.01));
      expect(layout.cardH, closeTo(800 * 0.74 * 600 / 800, 0.01));
      expect(layout.viewportFraction, closeTo((800 * 0.74 + 20) / 800, 0.01));
      // 卡片宽高比 = 屏幕宽高比
      expect(layout.cardH / layout.cardW, closeTo(600 / 800, 0.001));
    });
  });

  testWidgets('每个实例渲染一张卡片与一个 tab', (tester) async {
    final rec = _Recorder();
    await tester.pumpWidget(_Host(
      initial: [_inst('a', '跳跳球大冒险'), _inst('b', '消消乐星球')],
      rec: rec,
    ));
    expect(find.byKey(const ValueKey('mp-task-card-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('mp-task-card-b')), findsOneWidget);
    // 卡片头显示 App 名
    expect(find.text('跳跳球大冒险'), findsWidgets);
    expect(rec.viewClosed, 0);
  });

  testWidgets('点卡片 → onRestore(appid) 且 onCloseView 被调', (tester) async {
    final rec = _Recorder();
    await tester.pumpWidget(_Host(
      initial: [_inst('a', '跳跳球大冒险'), _inst('b', '消消乐星球')],
      rec: rec,
    ));
    await tester.tap(find.byKey(const ValueKey('mp-task-card-a')));
    await tester.pump();
    expect(rec.restored, ['a']);
    expect(rec.viewClosed, 1);
    expect(rec.closed, isEmpty);
  });

  testWidgets('卡片上滑(Dismissible up)→ onClose(appid)', (tester) async {
    final rec = _Recorder();
    await tester.pumpWidget(_Host(
      initial: [_inst('a', '跳跳球大冒险'), _inst('b', '消消乐星球')],
      rec: rec,
    ));
    await tester.drag(
        find.byKey(const ValueKey('dismiss-a')), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(rec.closed, ['a']);
    // 宿主移除实例 a 后,卡片 a 不再渲染
    expect(find.byKey(const ValueKey('mp-task-card-a')), findsNothing);
    expect(find.byKey(const ValueKey('mp-task-card-b')), findsOneWidget);
  });

  testWidgets('点卡片外空白 → onCloseView', (tester) async {
    final rec = _Recorder();
    await tester.pumpWidget(_Host(
      initial: [_inst('a', '跳跳球大冒险'), _inst('b', '消消乐星球')],
      rec: rec,
    ));
    // 卡片垂直居中(下缘约 y=554),570 在卡片下方空白区
    await tester.tapAt(const Offset(20, 570));
    await tester.pump();
    expect(rec.viewClosed, 1);
    expect(rec.restored, isEmpty);
    expect(rec.closed, isEmpty);
  });

  testWidgets('系统返回(PopScope)→ onCloseView', (tester) async {
    final rec = _Recorder();
    await tester.pumpWidget(_Host(
      initial: [_inst('a', '跳跳球大冒险'), _inst('b', '消消乐星球')],
      rec: rec,
    ));
    final handled = await tester.binding.handlePopRoute();
    expect(handled, isTrue);
    await tester.pump();
    expect(rec.viewClosed, 1);
    expect(rec.restored, isEmpty);
  });
}
