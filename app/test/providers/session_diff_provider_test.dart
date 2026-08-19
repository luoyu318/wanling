import 'package:wanling_core/models/session_diff.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/session_diff_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('happy path → AsyncData([2 files])', () async {
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {
              'files': [
                {'file': 'a.go', 'patch': '@@ -1 +1 @@', 'additions': 5, 'deletions': 2, 'status': 'modified'},
                {'file': 'b.go', 'patch': '', 'additions': 0, 'deletions': 3, 'status': 'deleted'},
              ],
            });

    final container = makeContainer();
    final state = container.read(sessionDiffProvider(
      (agentId: 'agent-1', convId: 'conv-1'),
    ).notifier);

    await state.load();
    final value = container.read(sessionDiffProvider(
      (agentId: 'agent-1', convId: 'conv-1'),
    ));

    expect(value, isA<AsyncData<List<SessionDiffFile>>>());
    expect(value.value!, [
      const SessionDiffFile(file: 'a.go', patch: '@@ -1 +1 @@', additions: 5, deletions: 2, status: 'modified'),
      const SessionDiffFile(file: 'b.go', patch: '', additions: 0, deletions: 3, status: 'deleted'),
    ]);
  });

  test('RpcException(-32601) → AsyncError', () async {
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-x'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenThrow(const RpcException(code: -32601, message: 'session not created'));

    final container = makeContainer();
    final state = container.read(sessionDiffProvider(
      (agentId: 'agent-1', convId: 'conv-x'),
    ).notifier);

    await state.load();
    final value = container.read(sessionDiffProvider(
      (agentId: 'agent-1', convId: 'conv-x'),
    ));

    expect(value.hasError, true);
    expect((value.error as RpcException).code, -32601);
  });

  test('RpcException(-32001) → AsyncError', () async {
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenThrow(const RpcException(code: -32001, message: 'plugin offline'));

    final container = makeContainer();
    final state = container.read(sessionDiffProvider(
      (agentId: 'agent-1', convId: 'conv-1'),
    ).notifier);

    await state.load();
    final value = container.read(sessionDiffProvider(
      (agentId: 'agent-1', convId: 'conv-1'),
    ));

    expect(value.hasError, true);
    expect((value.error as RpcException).code, -32001);
  });

  test('空 files 数组 → AsyncData([])', () async {
    when(() => api.rpc('agent-1', 'session.diff', {'wanling_conv_id': 'conv-1'},
            timeoutMs: any(named: 'timeoutMs')))
        .thenAnswer((_) async => {'files': []});

    final container = makeContainer();
    final state = container.read(sessionDiffProvider(
      (agentId: 'agent-1', convId: 'conv-1'),
    ).notifier);

    await state.load();
    final value = container.read(sessionDiffProvider(
      (agentId: 'agent-1', convId: 'conv-1'),
    ));

    expect(value, isA<AsyncData<List<SessionDiffFile>>>());
    expect(value.value!, isEmpty);
  });
}
