// miniProgramsProvider 修复回归:
// 1) 身份感知——账号变化(user.id)触发重新拉取,空窗期 401 的空结果不跨登录缓存
//    (曾致登录后首次进列表页恒「暂无小程序」,需手动刷新)
// 2) 鉴权失败(401/403)上抛不伪装空态;网络类错误维持返空(底栏 alive 收缩语义不变)
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/api_response.dart';
import 'package:wanling_core/services/api_service.dart';

class MockApi extends Mock implements ApiService {}

User _user(String id) => User(
      id: id,
      username: 'u_$id',
      createdAt: DateTime.parse('2026-06-13T00:00:00Z'),
    );

/// 鉴权失败经 dio 拦截器包装成 DioException(error: ApiException) 上抛
DioException _authErr(int statusCode) => DioException(
      requestOptions: RequestOptions(path: '/api/mini-programs'),
      error: ApiException('unauthorized', '未登录', statusCode: statusCode),
    );

void main() {
  late MockApi api;

  setUp(() {
    api = MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
    when(() => api.logout()).thenAnswer((_) async {});
    FlutterSecureStorage.setMockInitialValues({});
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('鉴权失败(401)上抛,不伪装成空列表', () async {
    when(() => api.getMiniPrograms()).thenThrow(_authErr(401));
    final c = makeContainer();
    final sub = c.listen(miniProgramsProvider, (_, _) {});
    addTearDown(sub.close);
    await expectLater(
      c.read(miniProgramsProvider.future),
      throwsA(isA<DioException>()),
    );
  });

  test('鉴权失败(403)同样上抛', () async {
    when(() => api.getMiniPrograms()).thenThrow(_authErr(403));
    final c = makeContainer();
    final sub = c.listen(miniProgramsProvider, (_, _) {});
    addTearDown(sub.close);
    await expectLater(
      c.read(miniProgramsProvider.future),
      throwsA(isA<DioException>()),
    );
  });

  test('网络类错误仍返空列表(底栏 mp 槽 alive 收缩语义不变)', () async {
    when(() => api.getMiniPrograms()).thenThrow(DioException(
      requestOptions: RequestOptions(path: '/api/mini-programs'),
      type: DioExceptionType.connectionError,
    ));
    final c = makeContainer();
    final sub = c.listen(miniProgramsProvider, (_, _) {});
    addTearDown(sub.close);
    expect(await c.read(miniProgramsProvider.future), isEmpty);
  });

  test('账号变化(user.id)触发重新拉取,空结果不跨登录缓存', () async {
    var calls = 0;
    when(() => api.getMiniPrograms()).thenAnswer((_) async {
      calls++;
      return <MiniProgramInfo>[];
    });
    final c = makeContainer();
    final notifier = c.read(authProvider.notifier);
    notifier.state = AuthState(user: _user('u1'), token: 't1');
    final sub = c.listen(miniProgramsProvider, (_, _) {});
    addTearDown(sub.close);

    await c.read(miniProgramsProvider.future);
    expect(calls, 1);

    // 切换账号:身份 id 变化 → provider 失效重建 → 重新拉取
    notifier.state = AuthState(user: _user('u2'), token: 't2');
    await c.read(miniProgramsProvider.future);
    expect(calls, 2);
  });

  test('同账号内 token 变化不触发重建(仅身份 id 驱动)', () async {
    var calls = 0;
    when(() => api.getMiniPrograms()).thenAnswer((_) async {
      calls++;
      return <MiniProgramInfo>[];
    });
    final c = makeContainer();
    final notifier = c.read(authProvider.notifier);
    notifier.state = AuthState(user: _user('u1'), token: 't1');
    final sub = c.listen(miniProgramsProvider, (_, _) {});
    addTearDown(sub.close);

    await c.read(miniProgramsProvider.future);
    // token 刷新(access 轮换)不改 user.id,不应触发 refetch
    notifier.state = AuthState(user: _user('u1'), token: 't1-new');
    await c.read(miniProgramsProvider.future);
    expect(calls, 1);
  });
}
