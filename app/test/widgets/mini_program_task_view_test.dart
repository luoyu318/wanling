// 小程序卡片多任务视图 widget 测试:
// 1. 渲染每个实例一个卡片(tab 数=instances.length)
// 2. 点卡片 → onRestore(appid) 且 onCloseView 被调
// 3. 卡片上滑(Dismissible up) → onClose(appid)
// 4. 点卡片外空白 → onCloseView
// 5. 系统返回(PopScope) → onCloseView
// 6. 实例元数据回填(D):name 空 + provider 有数据 → 显示真名真 icon URL;
//    provider 无数据 → 回退 appid
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/widgets/avatar.dart';
import 'package:app/widgets/mini_program_task_view.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements ApiService {}

MiniProgramInfo _mp(String appid, String name, String icon) =>
    MiniProgramInfo(
      id: 'id-$appid',
      appid: appid,
      ownerId: 'u1',
      name: name,
      version: 1,
      status: 'published',
      sha256: 'x',
      size: 1,
      icon: icon,
    );

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
  const _Host({
    required this.initial,
    required this.rec,
    this.programs = const [],
  });

  final List<MiniProgramInstance> initial;
  final _Recorder rec;

  /// 注册列表(供 TaskView 元数据回填 watch;默认空挡掉真请求)。
  final List<MiniProgramInfo> programs;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late final List<MiniProgramInstance> _instances = List.of(widget.initial);

  @override
  Widget build(BuildContext context) {
    final api = MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
    return ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        miniProgramsProvider.overrideWith((ref) async => widget.programs),
      ],
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

  group('实例元数据回填(D)', () {
    testWidgets('实例 name 空 + provider 有数据 → 显示真名真 icon URL',
        (tester) async {
      await tester.pumpWidget(_Host(
        initial: [MiniProgramInstance(appid: 'a', openedAt: DateTime.now())],
        rec: _Recorder(),
        programs: [_mp('a', '跳跳球大冒险', '/api/files/icon-a.png')],
      ));
      await tester.pump();

      // 打开瞬间快照为空(常为 appid),TaskView 必须显示 provider 真名
      expect(find.text('a'), findsNothing);
      expect(find.text('跳跳球大冒险'), findsWidgets);
      // icon 用 baseUrl 拼接的完整 URL
      final avatars = tester.widgetList<Avatar>(find.byType(Avatar)).toList();
      expect(avatars, isNotEmpty);
      for (final a in avatars) {
        expect(a.url, 'http://test.local/api/files/icon-a.png');
      }
    });

    testWidgets('provider 无数据 → 回退 appid', (tester) async {
      await tester.pumpWidget(_Host(
        initial: [MiniProgramInstance(appid: 'a', openedAt: DateTime.now())],
        rec: _Recorder(),
      ));
      await tester.pump();

      expect(find.text('a'), findsWidgets);
    });
  });

  group('卡片真实快照渲染(E)', () {
    testWidgets('实例带快照帧 → 卡片渲染 Image.memory(cacheWidth 400)',
        (tester) async {
      final inst = MiniProgramInstance(appid: 'a', openedAt: DateTime.now())
        ..name = '跳跳球大冒险'
        ..snapshot = _fakePng();
      await tester.pumpWidget(_Host(initial: [inst], rec: _Recorder()));

      final allImgs = tester
          .widgetList<Image>(find.byType(Image, skipOffstage: false))
          .toList();
      // cacheWidth 会让 Image.memory 把 MemoryImage 包成 ResizeImage
      final images = allImgs
          .where((w) =>
              w.image is ResizeImage &&
              (w.image as ResizeImage).imageProvider is MemoryImage)
          .toList();
      expect(images, isNotEmpty);
      // 内存约束:解码宽度限 ~400,防多实例大帧爆内存
      for (final img in images) {
        expect((img.image as ResizeImage).width, 400);
      }
    });

    testWidgets('无快照帧 → 不渲染 Image(占位渐变兜底)', (tester) async {
      await tester.pumpWidget(_Host(
        initial: [_inst('a', '跳跳球大冒险')],
        rec: _Recorder(),
      ));

      expect(
        tester.widgetList<Image>(find.byType(Image)),
        isEmpty,
      );
    });
  });
}

/// 假帧字节(非真实 PNG,Image 走 errorBuilder 占位,断言只看 widget 存在性)。
Uint8List _fakePng() => Uint8List.fromList([1, 2, 3, 4]);
