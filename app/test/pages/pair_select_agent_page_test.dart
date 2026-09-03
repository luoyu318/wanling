import 'package:wanling_core/models/pairing.dart';
import 'package:app/pages/pair_select_agent_page.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements ApiService {}

/// 配对页挂最小 GoRouter:配对成功路径会 context.go('/'),无 router 会断言失败。
Widget _harness(ApiService api) {
  final router = GoRouter(
    initialLocation: '/pair/select-agent',
    routes: [
      GoRoute(
        path: '/pair/select-agent',
        builder: (_, _) => const PairSelectAgentPage(ticketId: 't1'),
      ),
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('首页')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [apiProvider.overrideWithValue(api)],
    child: MaterialApp.router(routerConfig: router),
  );
}

void main() {
  testWidgets('PairSelectAgentPage 渲染 agent 列表', (tester) async {
    final api = MockApi();
    when(() => api.pairScan(any())).thenAnswer((_) async => PairScanResult(
          agents: [
            PairAgentSummary(
                id: 'a1', name: '列表项1', avatarUrl: null, bio: null, status: 'online'),
          ],
        ));

    await tester.pumpWidget(_harness(api));
    // 触发 pairScan 的 FutureBuilder
    await tester.pumpAndSettle();

    expect(find.text('列表项1'), findsOneWidget);
    expect(find.text('新建 Agent'), findsOneWidget);
  });

  testWidgets('点击新建 Agent 弹出输入框', (tester) async {
    final api = MockApi();
    when(() => api.pairScan(any())).thenAnswer((_) async => PairScanResult(
          agents: [],
        ));

    await tester.pumpWidget(_harness(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建 Agent'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AlertDialog, '新建 Agent'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('点击已有 agent 弹三选:标题/授权/接管/取消/备注 placeholder', (tester) async {
    final api = MockApi();
    when(() => api.pairScan(any())).thenAnswer((_) async => PairScanResult(
          agents: [
            PairAgentSummary(
                id: 'a1', name: '列表项1', avatarUrl: null, bio: null, status: 'online'),
          ],
        ));

    await tester.pumpWidget(_harness(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('列表项1'));
    await tester.pumpAndSettle();

    // 定稿 UI 文案
    expect(find.text('如何授权该 Agent？'), findsOneWidget);
    expect(find.text('授权技能使用'), findsOneWidget);
    expect(find.text('发放子密钥，不影响现有绑定'), findsOneWidget);
    expect(find.text('接管绑定'), findsOneWidget);
    expect(find.text('重置主密钥，原绑定将失效'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    // 备注输入 placeholder「技能授权」
    expect(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.hintText == '技能授权'),
        findsOneWidget);
    // 未发 complete 请求
    verifyNever(() => api.pairComplete(any(),
        agentId: any(named: 'agentId'),
        newAgentName: any(named: 'newAgentName'),
        action: any(named: 'action'),
        note: any(named: 'note')));
  });

  testWidgets('三选→授权技能使用:pairComplete 带 action=authorize + note', (tester) async {
    final api = MockApi();
    when(() => api.pairScan(any())).thenAnswer((_) async => PairScanResult(
          agents: [
            PairAgentSummary(
                id: 'a1', name: '列表项1', avatarUrl: null, bio: null, status: 'online'),
          ],
        ));
    // 全 named 参数显式注册,对齐生产调用形状(命名参数全集)
    when(() => api.pairComplete(any(),
        agentId: any(named: 'agentId'),
        newAgentName: any(named: 'newAgentName'),
        action: any(named: 'action'),
        note: any(named: 'note'))).thenAnswer(
        (_) async => PairCompleteResult(agentId: 'a1', agentName: '列表项1'));

    await tester.pumpWidget(_harness(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('列表项1'));
    await tester.pumpAndSettle();
    // 填备注后点授权
    await tester.enterText(
        find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.hintText == '技能授权'),
        '我的技能');
    await tester.tap(find.text('授权技能使用'));
    await tester.pumpAndSettle();

    verify(() => api.pairComplete('t1',
        agentId: 'a1',
        newAgentName: null,
        action: 'authorize',
        note: '我的技能')).called(1);
  });

  testWidgets('三选→接管绑定:重置确认弹窗→确定→pairComplete 带 action=bind', (tester) async {
    final api = MockApi();
    when(() => api.pairScan(any())).thenAnswer((_) async => PairScanResult(
          agents: [
            PairAgentSummary(
                id: 'a1', name: '列表项1', avatarUrl: null, bio: null, status: 'online'),
          ],
        ));
    when(() => api.pairComplete(any(),
        agentId: any(named: 'agentId'),
        newAgentName: any(named: 'newAgentName'),
        action: any(named: 'action'),
        note: any(named: 'note'))).thenAnswer(
        (_) async => PairCompleteResult(agentId: 'a1', agentName: '列表项1'));

    await tester.pumpWidget(_harness(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('列表项1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('接管绑定'));
    await tester.pumpAndSettle();
    // sheet 关闭,先出重置确认弹窗(破坏性操作二次确认)
    expect(find.text('重置密钥'), findsOneWidget);
    expect(find.text('确定重置'), findsOneWidget);
    await tester.tap(find.text('确定重置'));
    await tester.pumpAndSettle();

    verify(() => api.pairComplete('t1',
        agentId: 'a1',
        newAgentName: null,
        action: 'bind',
        note: null)).called(1);
  });

  testWidgets('三选→取消:不发 complete 请求', (tester) async {
    final api = MockApi();
    when(() => api.pairScan(any())).thenAnswer((_) async => PairScanResult(
          agents: [
            PairAgentSummary(
                id: 'a1', name: '列表项1', avatarUrl: null, bio: null, status: 'online'),
          ],
        ));

    await tester.pumpWidget(_harness(api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('列表项1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    verifyNever(() => api.pairComplete(any(),
        agentId: any(named: 'agentId'),
        newAgentName: any(named: 'newAgentName'),
        action: any(named: 'action'),
        note: any(named: 'note')));
  });
}
