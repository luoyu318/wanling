import 'package:app/models/pairing.dart';
import 'package:app/pages/pair_select_agent_page.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  testWidgets('PairSelectAgentPage 渲染 agent 列表', (tester) async {
    final api = MockApi();
    when(() => api.pairScan(any())).thenAnswer((_) async => PairScanResult(
          agents: [
            PairAgentSummary(
                id: 'a1', name: '列表项1', avatarUrl: null, bio: null, status: 'online'),
          ],
        ));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: PairSelectAgentPage(ticketId: 't1')),
      ),
    );
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
    when(() => api.pairComplete(any(), newAgentName: any(named: 'newAgentName')))
        .thenAnswer((_) async => PairCompleteResult(agentId: 'new1', agentName: '新建项'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: PairSelectAgentPage(ticketId: 't1')),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('新建 Agent'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AlertDialog, '新建 Agent'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
  });
}
