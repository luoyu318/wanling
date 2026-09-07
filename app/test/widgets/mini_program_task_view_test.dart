// 小程序卡片多任务视图 widget 测试:
// 1. 渲染每个实例一张卡片与卡外标题(队列卡组)
// 2. 点卡片 → onRestore(appid) 且 onCloseView 被调
// 3. 卡片上滑(Dismissible up) → onClose(appid)
// 4. 点卡片外空白 → onCloseView
// 5. 系统返回(PopScope) → onCloseView
// 6. 实例元数据回填(D):name 空 + provider 有数据 → 显示真名真 icon URL;
//    provider 无数据 → 回退 appid
// 7. 右滑跟手展开(波传导:右侧卡先动行程大) / 左滑跟手折叠
// 8. 堆叠态最多露 3 张,第 4 张起完全遮死;标题 icon 恒显、名称渐隐
// 9. 卡高按快照真实宽高比(无留边);底部 X → onCloseAll + onCloseView
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
  int allCleared = 0;
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
          onCloseAll: () => widget.rec.allCleared++,
        ),
      ),
    );
  }
}

void main() {
  group('taskCardLayout 布局纯函数', () {
    test('卡片宽 0.56 屏宽,高整屏等比', () {
      final layout = taskCardLayout(const Size(800, 600));
      expect(layout.cardW, closeTo(800 * 0.56, 0.01));
      expect(layout.cardH, closeTo(800 * 0.56 * 600 / 800, 0.01));
      // 卡片宽高比 = 屏幕宽高比
      expect(layout.cardH / layout.cardW, closeTo(600 / 800, 0.001));
    });
  });

  testWidgets('每个实例渲染一张卡片与卡外标题(无锁/无顶部tab)', (tester) async {
    final rec = _Recorder();
    await tester.pumpWidget(_Host(
      initial: [_inst('a', '跳跳球大冒险'), _inst('b', '消消乐星球')],
      rec: rec,
    ));
    expect(find.byKey(const ValueKey('mp-task-card-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('mp-task-card-b')), findsOneWidget);
    // 卡外标题行显示 App 名
    expect(find.text('跳跳球大冒险'), findsWidgets);
    // 锁标识已移除(产品决策)
    expect(find.byIcon(Icons.lock_outline), findsNothing);
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
    // 卡片垂直居中(下缘约 y=497),570 在卡片下方空白区
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

  group('堆叠卡组交互(澎湃 OS 样式)', () {
    /// 卡组中卡 appid 的缩放系数(近大远小断言用):
    /// 定位 child 为该卡 _TaskCard(带 mp-task-card key)的 Transform.scale,
    /// 读矩阵 x 轴缩放分量(storage 列优先,[0] 即 scaleX)。
    double deckScale(WidgetTester tester, String appid) {
      final t = tester.widget<Transform>(find.byWidgetPredicate(
        (w) => w is Transform && w.child?.key == ValueKey('mp-task-card-$appid'),
      ));
      return t.transform.storage[0];
    }

    testWidgets('右滑跟手展开:前台卡位移大于后层卡,松手停留', (tester) async {
      final rec = _Recorder();
      await tester.pumpWidget(_Host(
        initial: [_inst('a', '跳跳球大冒险'), _inst('b', '消消乐星球')],
        rec: rec,
      ));
      final frontBefore =
          tester.getTopLeft(find.byKey(const ValueKey('mp-task-card-a')));
      final backBefore =
          tester.getTopLeft(find.byKey(const ValueKey('mp-task-card-b')));
      await tester.drag(
          find.byKey(const ValueKey('mp-task-card-a')), const Offset(240, 0));
      await tester.pumpAndSettle();
      final frontAfter =
          tester.getTopLeft(find.byKey(const ValueKey('mp-task-card-a')));
      final backAfter =
          tester.getTopLeft(find.byKey(const ValueKey('mp-task-card-b')));
      // 前台卡右移最多,后层按比例递减
      expect(frontAfter.dx - frontBefore.dx, greaterThan(0));
      expect(frontAfter.dx - frontBefore.dx,
          greaterThan(backAfter.dx - backBefore.dx));
      // 松手停留:视图未关、未触发恢复
      expect(rec.viewClosed, 0);
      expect(rec.restored, isEmpty);
    });

    testWidgets('左滑跟手折叠:展开后再左滑回到原位', (tester) async {
      final rec = _Recorder();
      await tester.pumpWidget(_Host(
        initial: [_inst('a', '跳跳球大冒险'), _inst('b', '消消乐星球')],
        rec: rec,
      ));
      final before =
          tester.getTopLeft(find.byKey(const ValueKey('mp-task-card-a')));
      await tester.drag(
          find.byKey(const ValueKey('mp-task-card-a')), const Offset(240, 0));
      await tester.pumpAndSettle();
      await tester.drag(
          find.byKey(const ValueKey('mp-task-card-a')), const Offset(-240, 0));
      await tester.pumpAndSettle();
      final after =
          tester.getTopLeft(find.byKey(const ValueKey('mp-task-card-a')));
      expect(after.dx, closeTo(before.dx, 0.5));
      expect(rec.viewClosed, 0);
    });

    testWidgets('快速轻扫 → 惯性滑行收敛到全展开边界', (tester) async {
      final rec = _Recorder();
      await tester.pumpWidget(_Host(
        initial: [_inst('a', '跳跳球大冒险'), _inst('b', '消消乐星球')],
        rec: rec,
      ));
      await tester.fling(find.byKey(const ValueKey('mp-task-card-a')),
          const Offset(200, 0), 3000);
      await tester.pumpAndSettle();
      final front =
          tester.getTopLeft(find.byKey(const ValueKey('mp-task-card-a')));
      // 惯性钳制在 fan=1(队列模型):前台卡左缘 = base + (n-1)*step
      // = 0.16*800 + 0.70*448 = 128 + 313.6 = 441.6
      expect(front.dx, closeTo(441.6, 1));
      expect(rec.viewClosed, 0);
    });

    testWidgets('底部 X → onCloseAll + onCloseView', (tester) async {
      final rec = _Recorder();
      await tester.pumpWidget(_Host(
        initial: [_inst('a', '跳跳球大冒险')],
        rec: rec,
      ));
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(rec.allCleared, 1);
      expect(rec.viewClosed, 1);
    });

    testWidgets('卡体为整屏等比(卡宽 448 → 卡高 336)', (tester) async {
      final inst = MiniProgramInstance(appid: 'a', openedAt: DateTime.now())
        ..name = '跳跳球大冒险'
        ..snapshot = _fakePng();
      await tester.pumpWidget(_Host(initial: [inst], rec: _Recorder()));
      final body =
          tester.getSize(find.byKey(const ValueKey('mp-card-body-a')));
      // 卡宽 0.56*800=448,高整屏等比 336
      expect(body.width, closeTo(448, 0.5));
      expect(body.height, closeTo(336, 0.5));
    });

    testWidgets('有快照真实宽高比 → 卡框按快照比例等比缩放(消除黑边)',
        (tester) async {
      // 竖屏 surface(对齐真机形态):卡高 = 卡宽/0.6 才放得下
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final inst = MiniProgramInstance(appid: 'a', openedAt: DateTime.now())
        ..name = '跳跳球大冒险'
        ..snapshot = _fakePng()
        ..snapshotAspect = 0.6; // w/h,卡高 = 336/0.6 = 560
      await tester.pumpWidget(_Host(initial: [inst], rec: _Recorder()));
      final body =
          tester.getSize(find.byKey(const ValueKey('mp-card-body-a')));
      expect(body.width, closeTo(336, 0.5));
      expect(body.height, closeTo(336 / 0.6, 0.5));
    });

    testWidgets('堆叠态:前台卡在基准位,后卡贴屏幕左缘微错开(参考图 1)',
        (tester) async {
      final rec = _Recorder();
      await tester.pumpWidget(_Host(
        initial: [
          _inst('a', '跳跳球大冒险'),
          _inst('b', '消消乐星球'),
          _inst('c', '万灵日历'),
          _inst('d', '共享清单'),
        ],
        rec: rec,
      ));
      double dx(String id) => tester
          .getTopLeft(find.byKey(ValueKey('mp-task-card-$id')))
          .dx;
      // 前台卡基准位 0.16*800=128;后卡全部贴左缘,相邻 12px 错开露层
      expect(dx('a'), closeTo(128, 0.5));
      expect(dx('b'), closeTo(0, 0.5));
      expect(dx('c'), closeTo(-12, 0.5));
      expect(dx('d'), closeTo(-24, 0.5));
      // 近大远小:每深一层缩 5%,下限 0.85
      expect(deckScale(tester, 'a'), closeTo(1.0, 0.001));
      expect(deckScale(tester, 'b'), closeTo(0.95, 0.001));
      expect(deckScale(tester, 'c'), closeTo(0.90, 0.001));
      expect(deckScale(tester, 'd'), closeTo(0.85, 0.001));
    });

    testWidgets('统一插值展开:前台/次卡/末卡位移依次递减,相邻卡间距不超卡宽(无断裂缝隙)',
        (tester) async {
      final rec = _Recorder();
      await tester.pumpWidget(_Host(
        initial: [
          _inst('a', '跳跳球大冒险'),
          _inst('b', '消消乐星球'),
          _inst('c', '万灵日历'),
        ],
        rec: rec,
      ));
      double dx(String id) => tester
          .getTopLeft(find.byKey(ValueKey('mp-task-card-$id')))
          .dx;
      final aBefore = dx('a'), bBefore = dx('b'), cBefore = dx('c');
      // 全程 dx = clamp(2*313.6*0.5, 280, 520) = 313.6,拖 240:
      // 统一 fan 插值,位移 ∝ 行程(前台 > 次卡 > 末卡,右大左小)
      await tester.drag(
          find.byKey(const ValueKey('mp-task-card-a')), const Offset(240, 0));
      await tester.pumpAndSettle();
      final aMoved = dx('a') - aBefore;
      final bMoved = dx('b') - bBefore;
      final cMoved = dx('c') - cBefore;
      expect(aMoved, greaterThan(bMoved));
      expect(bMoved, greaterThan(cMoved));
      expect(cMoved, greaterThan(0));
      // 任意时刻相邻卡间距 ≤ step(0.84 卡宽),队列紧密衔接不露背景
      expect(dx('a') - dx('b'), lessThan(448 * 0.70 + 1));
      expect(dx('b') - dx('c'), lessThan(448 * 0.70 + 1));
      expect(rec.viewClosed, 0);
    });

    testWidgets('标题行为:堆叠态次卡标题全隐;卡被推时 icon 先现、名称后现;前台恒显',
        (tester) async {
      final rec = _Recorder();
      await tester.pumpWidget(_Host(
        initial: [
          _inst('a', '跳跳球大冒险'),
          _inst('b', '消消乐星球'),
          _inst('c', '万灵日历'),
        ],
        rec: rec,
      ));
      double nameOp(String name) => tester
          .widget<Opacity>(find.ancestor(
              of: find.text(name), matching: find.byType(Opacity)))
          .opacity;
      double iconOp(String appid) => tester
          .widget<Opacity>(find.ancestor(
              of: find.descendant(
                  of: find.byKey(ValueKey('mp-task-card-$appid')),
                  matching: find.byType(Avatar)),
              matching: find.byType(Opacity)))
          .opacity;

      // 堆叠态:前台标题完整,次卡/末卡标题全隐(卡未被动过)
      expect(iconOp('a'), 1.0);
      expect(nameOp('跳跳球大冒险'), 1.0);
      expect(iconOp('b'), 0.0);
      expect(nameOp('消消乐星球'), 0.0);

      // n=3 全程 dx=376.32,拖 200(扣 slop 后 fan≈0.52~0.57):
      // 波前 w=fan*n≈1.3~1.45:次卡(i=1)名称半透、icon 已满;
      // 末卡(i=2)名称未到、icon 提前一级微显(参考图 3 最左窄条只 icon)。
      // 区间断言容忍 touch slop 误差。
      await tester.drag(
          find.byKey(const ValueKey('mp-task-card-a')), const Offset(200, 0));
      await tester.pumpAndSettle();
      final icon = iconOp('b'), name = nameOp('消消乐星球');
      expect(icon, 1.0);
      expect(name, inInclusiveRange(0.5, 0.8));
      expect(iconOp('c'), inInclusiveRange(0.5, 0.8));
      expect(nameOp('万灵日历'), 0.0);
      expect(rec.viewClosed, 0);
    });

    testWidgets('拖到底 fan=1:全部标题可见(含最老卡,参考图 5)', (tester) async {
      final rec = _Recorder();
      await tester.pumpWidget(_Host(
        initial: [
          _inst('a', '跳跳球大冒险'),
          _inst('b', '消消乐星球'),
        ],
        rec: rec,
      ));
      double nameOp(String name) => tester
          .widget<Opacity>(find.ancestor(
              of: find.text(name), matching: find.byType(Opacity)))
          .opacity;
      double iconOp(String appid) => tester
          .widget<Opacity>(find.ancestor(
              of: find.descendant(
                  of: find.byKey(ValueKey('mp-task-card-$appid')),
                  matching: find.byType(Avatar)),
              matching: find.byType(Opacity)))
          .opacity;
      // 快速轻扫 → 惯性到 fan=1,波前扫完全队;展开态各卡等大
      await tester.fling(find.byKey(const ValueKey('mp-task-card-a')),
          const Offset(200, 0), 3000);
      await tester.pumpAndSettle();
      expect(iconOp('b'), 1.0);
      expect(nameOp('消消乐星球'), 1.0);
      expect(deckScale(tester, 'b'), closeTo(1.0, 0.001));
      expect(rec.viewClosed, 0);
    });
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
      // 内存约束:清晰层解码宽度限 ~400,防多实例大帧爆内存
      expect(
        images.any((img) => (img.image as ResizeImage).width == 400),
        isTrue,
      );
      // letterbox 填充:模糊底层用 80 小图解码
      expect(
        images.any((img) => (img.image as ResizeImage).width == 80),
        isTrue,
      );
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
