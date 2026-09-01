// 小程序列表页(宫格)widget 测试:分组渲染/disabled 停用后缀/空态/
// 长按菜单(固定到底栏→navOrder mp 槽/取消固定/删除确认文案按 pinned 分化)。
// harness 对齐 conv_action_menu_test:apiProvider 用 mocktail MockApi stub baseUrl,
// sharedPrefsProvider 显式注入 mock SharedPreferences(navOrderProvider 硬依赖)。
import 'package:app/pages/mini_program_list_page.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart'
    show sharedPrefsProvider;
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockApi extends Mock implements ApiService {}

MiniProgramInfo _mp(String appid, {String status = 'published'}) =>
    MiniProgramInfo(
      id: 'id-$appid',
      appid: appid,
      ownerId: 'u1',
      name: '应用-$appid',
      version: 1,
      status: status,
      sha256: 'x',
      size: 1,
    );

/// 登出中间态(匿名)下 NavOrderNotifier 仍可在内存 pin/unpin,
/// 断言只关心 provider 状态,不依赖持久化 key。
Future<ProviderContainer> _pump(
  WidgetTester tester,
  List<MiniProgramInfo> list,
) async {
  SharedPreferences.setMockInitialValues({});
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test');
  final container = ProviderContainer(overrides: [
    miniProgramsProvider.overrideWith((ref) async => list),
    apiProvider.overrideWithValue(api),
    sharedPrefsProvider
        .overrideWithValue(await SharedPreferences.getInstance()),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: MiniProgramListPage()),
  ));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('宫格按组渲染,disabled 项带停用后缀', (tester) async {
    await _pump(tester, [
      _mp('pub-a'),
      _mp('mine-a', status: 'private'),
      _mp('mine-b', status: 'disabled'),
    ]);

    expect(find.text('公共库'), findsOneWidget);
    expect(find.text('我的'), findsOneWidget);
    expect(find.text('应用-pub-a'), findsOneWidget);
    expect(find.text('应用-mine-a'), findsOneWidget);
    expect(find.text('应用-mine-b·停用'), findsOneWidget);
  });

  testWidgets('空列表展示空态', (tester) async {
    await _pump(tester, const []);

    expect(find.text('暂无小程序'), findsOneWidget);
  });

  testWidgets('长按私有项弹菜单:固定到底栏 → navOrder 含 mp 槽 → 再长按变取消固定',
      (tester) async {
    final container = await _pump(tester, [
      _mp('pub-a'),
      _mp('mine-a', status: 'private'),
    ]);

    // 长按私有项 → 底部菜单含 删除 + 固定到底栏。
    await tester.longPress(find.text('应用-mine-a'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('固定到底栏'), findsOneWidget);

    // 点固定 → 菜单关,navOrder 含 mp 槽。
    await tester.tap(find.text('固定到底栏'));
    await tester.pumpAndSettle();
    expect(
      container.read(navOrderProvider).contains(navMpRef('mine-a')),
      isTrue,
    );

    // 再长按 → 菜单变「取消固定」。
    await tester.longPress(find.text('应用-mine-a'));
    await tester.pumpAndSettle();
    expect(find.text('取消固定'), findsOneWidget);
  });

  testWidgets('删除确认框文案按 pinned 分化;取消不执行', (tester) async {
    final container = await _pump(tester, [_mp('mine-a', status: 'private')]);

    // 未固定:普通文案(无「一并移除」)。
    await tester.longPress(find.text('应用-mine-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除小程序?'), findsOneWidget);
    expect(find.textContaining('一并移除'), findsNothing);

    // 取消 → 不执行,条目保留。
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除小程序?'), findsNothing);
    expect(find.text('应用-mine-a'), findsOneWidget);

    // 固定后:文案提示一并移除。
    container.read(navOrderProvider.notifier).pin(navMpRef('mine-a'));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('应用-mine-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('一并移除'), findsOneWidget);
  });

  testWidgets('删除确认后触发 service(测试环境网络失败 → SnackBar 反馈)',
      (tester) async {
    // TokenVault 注入登录态,否则 delete 走到 token 空校验即失败。
    FlutterSecureStorage.setMockInitialValues({'access_token': 't'});
    final container = await _pump(tester, [_mp('mine-a', status: 'private')]);
    // 预固定:删除失败必须保留固定关系(删除成功才 unpin)。
    container.read(navOrderProvider.notifier).pin(navMpRef('mine-a'));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('应用-mine-a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('删除失败'), findsOneWidget);
    expect(
      container.read(navOrderProvider).contains(navMpRef('mine-a')),
      isTrue,
    );
  });
}
