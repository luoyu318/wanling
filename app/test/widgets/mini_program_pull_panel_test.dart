// MiniProgramPullScope 交互测试(消息页下拉拉出小程序面板):
// - 下拉全程跟手:页面 Transform.translate 下移,面板 Opacity 淡入
// - 阈值分档:>=190 补完打开 / >=60 轻拉刷新 / <60 弹回
// - 完成态:面板 Opacity==1 且 panelOpenNotifier 置 true(底栏收缩由宿主管)
// - 完成态上滑跟手恢复(未拖过半弹回完成态,拖过半松手收回);点页头收回
// - 面板内容:最近使用(manager)/常用(miniProgramsProvider 前 8)两组 4 列网格
//
// 几何口径(默认测试面 800x600,无系统 inset):
//   tMax = 600 - 26(点指示器) - 0(状态栏) - 56(AppBar) - 0(手势条) = 518
//   触摸 slop 18px:拖 240px 实际 overscroll 222(>190 补完段)
//   拖 100px 实际 82(60~190 刷新段);拖 30px 实际 12(<60 弹回段)
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/widgets/avatar.dart';
import 'package:app/widgets/mini_program_pull_panel.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockApi extends Mock implements ApiService {}

MiniProgramInfo _mp(String appid, String name) => MiniProgramInfo(
      id: 'id-$appid',
      appid: appid,
      ownerId: 'u1',
      name: name,
      version: 1,
      status: 'published',
      sha256: 'x',
      size: 1,
    );

const _headerKey = ValueKey('pull-header');
const _childText = 'child-content';

Widget _stubChild() => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        SizedBox(height: 100),
        Center(child: Text(_childText)),
        SizedBox(height: 600),
      ],
    );

/// 页面卡片下移量(卡片层 Transform.translate 按 key 定位,读平移矩阵 y 分量)。
double _cardOffsetDy(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(const ValueKey('pull-card')))
    .transform
    .getTranslation()
    .y;

/// 面板可见度(Opacity 是 MiniProgramPanel 的直接包装层)。
Opacity _panelOpacity(WidgetTester tester) => tester.widget<Opacity>(
      find.ancestor(
        of: find.byType(MiniProgramPanel),
        matching: find.byType(Opacity),
      ),
    );

Future<void> _pumpScope(
  WidgetTester tester, {
  required ValueNotifier<bool> openNotifier,
  required void Function() onRefreshCall,
  required void Function(String appid) onOpenAppCall,
  List<MiniProgramInfo> programs = const [],
  MiniProgramManager? manager,
}) async {
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  await tester.pumpWidget(UncontrolledProviderScope(
    container: ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      miniProgramsProvider.overrideWith((ref) async => programs),
      if (manager != null)
        miniProgramManagerProvider.overrideWith((ref) => manager),
    ]),
    child: MaterialApp(
      home: Scaffold(
        body: MiniProgramPullScope(
          panelOpenNotifier: openNotifier,
          header: Container(
            key: _headerKey,
            height: 56,
            color: Colors.white,
            alignment: Alignment.center,
            child: const Text('stub-header'),
          ),
          onRefresh: () async => onRefreshCall(),
          onOpenApp: onOpenAppCall,
          child: _stubChild(),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

/// 顶部下拉:在 child 的 ListView 上按下向下拖 [dx] 后松手(可选拖中不松手)。
Future<TestGesture> _pullDown(
  WidgetTester tester,
  double distance, {
  bool release = false,
}) async {
  final g = await tester.startGesture(
    tester.getCenter(find.text(_childText)),
  );
  await g.moveBy(Offset(0, distance));
  await tester.pump();
  if (release) {
    await g.up();
    await g.removePointer();
  }
  return g;
}

/// 完成态前置:拖 240px 松手补完(含 settle 动画)。
Future<void> _completeOpen(WidgetTester tester) async {
  await _pullDown(tester, 240, release: true);
  await tester.pumpAndSettle();
}

void main() {
  late ValueNotifier<bool> openNotifier;
  var refreshCount = 0;
  final openedApps = <String>[];

  setUp(() {
    // Avatar 内部 watch settingsProvider(直连 SharedPreferences)与 authProvider;
    // secure storage 不 mock 会在 flutter test 环境挂起。
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    openNotifier = ValueNotifier<bool>(false);
    refreshCount = 0;
    openedApps.clear();
  });

  tearDown(() => openNotifier.dispose());

  Future<void> pump(WidgetTester tester,
          {List<MiniProgramInfo> programs = const [],
          MiniProgramManager? manager}) =>
      _pumpScope(
        tester,
        openNotifier: openNotifier,
        onRefreshCall: () => refreshCount++,
        onOpenAppCall: openedApps.add,
        programs: programs,
        manager: manager,
      );

  testWidgets('静止:无指示点,面板不可见,child 正常渲染', (tester) async {
    await pump(tester);

    expect(find.text(_childText), findsOneWidget);
    expect(find.byKey(const ValueKey('pull-dots')), findsNothing);
    expect(_panelOpacity(tester).opacity, 0);
    expect(_cardOffsetDy(tester), 0);
    // 完成态信号:关闭
    expect(openNotifier.value, isFalse);
  });

  testWidgets('顶部下拉跟手:页面位移>0,面板淡入,点指示器出现', (tester) async {
    await pump(tester);

    final g = await _pullDown(tester, 240);

    expect(_cardOffsetDy(tester), greaterThan(0));
    expect(_panelOpacity(tester).opacity, greaterThan(0));
    expect(find.byKey(const ValueKey('pull-dots')), findsOneWidget);

    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('拖过 190px 松手:补完打开(Opacity==1),onOpenApp 不触发', (tester) async {
    await pump(tester);

    await _pullDown(tester, 240, release: true);
    await tester.pumpAndSettle();

    expect(_panelOpacity(tester).opacity, 1);
    expect(openNotifier.value, isTrue, reason: '宿主据 notifier 收缩底栏');
    expect(openedApps, isEmpty);
    // 卡片停在完成态页头贴底位置
    expect(_cardOffsetDy(tester), 518);
  });

  testWidgets('拖 100px(60~190)松手:onRefresh 被调用,不进完成态', (tester) async {
    await pump(tester);

    await _pullDown(tester, 100, release: true);
    await tester.pumpAndSettle();

    expect(refreshCount, 1);
    expect(openNotifier.value, isFalse);
    expect(_panelOpacity(tester).opacity, 0);
  });

  testWidgets('拖 30px(<60)松手:弹回 offset==0,无刷新', (tester) async {
    await pump(tester);

    await _pullDown(tester, 30, release: true);
    await tester.pumpAndSettle();

    expect(refreshCount, 0);
    expect(openNotifier.value, isFalse);
    expect(_cardOffsetDy(tester), 0);
  });

  testWidgets('完成态上滑:跟手减小;小拖松手回完成态,拖过半松手收回', (tester) async {
    await pump(tester);
    await _completeOpen(tester);

    // 小拖:未拖过半(tMax*0.5=259),松手弹回完成态
    final g = await tester.startGesture(const Offset(400, 300));
    await g.moveBy(const Offset(0, -100));
    await tester.pump();
    expect(_cardOffsetDy(tester), 418, reason: '上滑跟手减小');
    await g.up();
    await tester.pumpAndSettle();
    expect(_cardOffsetDy(tester), 518);
    expect(openNotifier.value, isTrue);

    // 大拖:拖过半(pull 118 < 259),松手收回且面板消失
    final g2 = await tester.startGesture(const Offset(400, 300));
    await g2.moveBy(const Offset(0, -400));
    await tester.pump();
    await g2.up();
    await tester.pumpAndSettle();
    expect(_cardOffsetDy(tester), 0);
    expect(_panelOpacity(tester).opacity, 0);
    expect(openNotifier.value, isFalse);
  });

  testWidgets('完成态点底部页头区域 → 收回', (tester) async {
    await pump(tester);
    await _completeOpen(tester);

    await tester.tap(find.byKey(_headerKey), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(_cardOffsetDy(tester), 0);
    expect(openNotifier.value, isFalse);
  });

  testWidgets('面板内容:最近/常用两组 4 列网格,图标 Avatar radius 14', (tester) async {
    final manager = MiniProgramManager()
      ..open('a1', name: '跳跳球', iconUrl: '')
      ..open('a2', name: '消消乐', iconUrl: '')
      ..minimize();
    await pump(
      tester,
      programs: [_mp('b1', '音乐台'), _mp('b2', '备忘录'), _mp('b3', '随手记账')],
      manager: manager,
    );

    // 两组网格都是 4 列
    final grids = tester.widgetList<GridView>(find.byType(GridView)).toList();
    expect(grids.length, 2);
    for (final g in grids) {
      final delegate = g.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 4);
    }
    expect(find.text('最近使用'), findsOneWidget);
    expect(find.text('常用的小程序'), findsOneWidget);
    // 最近段展示实例元信息名
    expect(find.text('跳跳球'), findsOneWidget);
    // 图标:最近 2 + 常用 3 = 5 个 Avatar,样式对照 mini_program_list_page(56/radius 14)
    final avatars = tester.widgetList<Avatar>(find.byType(Avatar)).toList();
    expect(avatars.length, 5);
    for (final a in avatars) {
      expect(a.radius, 14);
      expect(a.size, 56);
    }
  });

  testWidgets('无最近实例:整段隐藏最近使用', (tester) async {
    await pump(tester, programs: [_mp('b1', '音乐台')]);

    expect(find.text('最近使用'), findsNothing);
    expect(find.text('常用的小程序'), findsOneWidget);
  });
}
