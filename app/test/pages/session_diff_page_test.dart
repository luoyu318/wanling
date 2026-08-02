import 'dart:async';

import 'package:app/pages/session_diff_page.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/services/api_service.dart';
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
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(overrides: [apiProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    return c;
  }

  Widget buildApp(ProviderContainer container) {
    final router = GoRouter(
      initialLocation: '/session-diff/agent-1/conv-1',
      routes: [
        GoRoute(
          path: '/session-diff/:agentId/:convId',
          builder: (_, state) => SessionDiffPage(
            agentId: state.pathParameters['agentId']!,
            convId: state.pathParameters['convId']!,
          ),
        ),
        GoRoute(
          path: '/session-diff-file/:agentId/:convId',
          builder: (_, state) => Scaffold(
            body: Text('file-idx-${state.uri.queryParameters['idx']}'),
          ),
        ),
      ],
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('加载中显菊花 + 「加载中...」', (tester) async {
    final completer = Completer<Map<String, dynamic>>();
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) => completer.future);
    addTearDown(() => completer.complete({}));

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('加载中...'), findsOneWidget);
  });

  testWidgets('文件列表渲染 badge + path + +X -Y', (tester) async {
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'files': [
                {'file': 'server/main.go', 'patch': '', 'additions': 8, 'deletions': 1, 'status': 'modified'},
                {'file': 'old/util.go', 'patch': '', 'additions': 0, 'deletions': 20, 'status': 'deleted'},
              ],
            });

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    expect(find.text('server/main.go'), findsOneWidget);
    expect(find.text('old/util.go'), findsOneWidget);
    expect(find.text('M'), findsOneWidget);
    expect(find.text('D'), findsOneWidget);
    expect(find.text('+8'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
    expect(find.text('−20'), findsOneWidget);
  });

  testWidgets('点文件行跳详情页(idx 索引)', (tester) async {
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'files': [
                {'file': 'a.go', 'patch': '', 'additions': 1, 'deletions': 0, 'status': 'added'},
                {'file': 'b.go', 'patch': '', 'additions': 0, 'deletions': 1, 'status': 'deleted'},
              ],
            });

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('b.go'));
    await tester.pumpAndSettle();

    expect(find.text('file-idx-1'), findsOneWidget);
  });

  testWidgets('RpcException(-32601) 显「暂无变更,发送首条消息后可查看」+ 无重试', (tester) async {
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenThrow(const RpcException(code: -32601, message: 'session not created'));

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    expect(find.textContaining('发送首条消息后'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('RpcException(-32001) 显「Agent 离线」+ 重试按钮', (tester) async {
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenThrow(const RpcException(code: -32001, message: 'plugin offline'));

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Agent 离线'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('空 files 显「暂无变更」+ 无重试', (tester) async {
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {'files': []});

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    expect(find.text('暂无变更'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('下拉刷新触发 refresh 走第二次 rpc(列表保留可见)', (tester) async {
    final calls = <int>[];
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs'))).thenAnswer((_) async {
      calls.add(1);
      // 第二次返回新数据,验证不闪菊花(保留旧列表)
      if (calls.length == 1) {
        return {
          'files': [
            {'file': 'a.go', 'patch': '', 'additions': 1, 'deletions': 0, 'status': 'added'},
          ],
        };
      }
      return {
        'files': [
          {'file': 'a.go', 'patch': '', 'additions': 1, 'deletions': 0, 'status': 'added'},
          {'file': 'b.go', 'patch': '', 'additions': 2, 'deletions': 0, 'status': 'added'},
        ],
      };
    });

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    expect(find.text('a.go'), findsOneWidget);
    expect(find.text('b.go'), findsNothing);
    expect(calls.length, 1);

    // 下拉触发 RefreshIndicator
    await tester.fling(find.text('a.go'), const Offset(0, 300), 1000);
    await tester.pump();

    // refresh 期间列表仍可见(不显全屏菊花)
    expect(find.text('a.go'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(calls.length, 2);
    expect(find.text('a.go'), findsOneWidget);
    expect(find.text('b.go'), findsOneWidget);
  });
}
