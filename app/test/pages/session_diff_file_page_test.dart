import 'package:app/pages/session_diff_file_page.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;

  setUp(() {
    api = MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'files': [
                {'file': 'main.go', 'patch': '@@ -1 +1 @@\n-old\n+new', 'additions': 1, 'deletions': 1, 'status': 'modified'},
                {'file': 'old.go', 'patch': '', 'additions': 0, 'deletions': 5, 'status': 'deleted'},
              ],
            });
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    return c;
  }

  Widget buildApp(ProviderContainer container, {required int idx}) {
    final router = GoRouter(
      initialLocation: '/session-diff-file/agent-1/conv-1?idx=$idx',
      routes: [
        GoRoute(
          path: '/session-diff-file/:agentId/:convId',
          builder: (_, state) => SessionDiffFilePage(
            agentId: state.pathParameters['agentId']!,
            convId: state.pathParameters['convId']!,
            idx: int.parse(state.uri.queryParameters['idx']!),
          ),
        ),
      ],
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('渲染文件名 + patch 内容', (tester) async {
    await tester.pumpWidget(buildApp(makeContainer(), idx: 0));
    await tester.pumpAndSettle();

    expect(find.text('main.go'), findsOneWidget);
    expect(find.textContaining('-old'), findsOneWidget);
    expect(find.textContaining('+new'), findsOneWidget);
  });

  testWidgets('渲染 header +X −Y', (tester) async {
    await tester.pumpWidget(buildApp(makeContainer(), idx: 0));
    await tester.pumpAndSettle();

    expect(find.text('+1'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
  });

  testWidgets('idx 越界显「文件不存在」', (tester) async {
    await tester.pumpWidget(buildApp(makeContainer(), idx: 99));
    await tester.pumpAndSettle();

    expect(find.textContaining('文件不存在'), findsOneWidget);
  });
}
