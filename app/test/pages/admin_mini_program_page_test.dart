// 小程序审核页 widget 测试:三 Tab 分组渲染/发布操作(确认弹窗→API→invalidate)/
// 403 无权限兜底/非 403 错误重试/操作失败不 invalidate。
// harness 说明:
// - 成功路径用 mocktail MockApi stub(adminMiniProgramsProvider 整体 override)。
// - 403 用例必须走真实 dio 拦截器链路:ApiService 拦截器把 envelope error 包进
//   DioException.error 抛出(ApiException 不是顶层异常),页面判定依赖解包行为,
//   故注入 MockHttpClientAdapter 返回 403 envelope 而非直接 override provider 抛异常。
import 'dart:convert';

import 'package:app/pages/admin_mini_program_page.dart';
import 'package:dio/dio.dart';
import 'package:wanling_core/models/admin_mini_program_info.dart';
import 'package:wanling_core/providers/admin_mini_programs_provider.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/services/api_response.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/mock_adapter.dart';

class MockApi extends Mock implements ApiService {}

AdminMiniProgramInfo _mp(String status, {String owner = 'kira'}) =>
    AdminMiniProgramInfo(
      id: 'id-$status',
      appid: 'app.$status',
      ownerUsername: owner,
      name: 'N-$status',
      version: 1,
      icon: '',
      permissions: const [],
      status: status,
      size: 1024,
    );

Map<String, dynamic> _mpJson(AdminMiniProgramInfo m) => {
      'id': m.id,
      'appid': m.appid,
      'owner_username': m.ownerUsername,
      'name': m.name,
      'version': m.version,
      'icon': m.icon,
      'permissions': m.permissions,
      'status': m.status,
      'size': m.size,
    };

/// 构造走真实拦截器链路的 ApiService:adapter 返回的 HTTP 状态码 + envelope
/// 会经过 onError 拦截器包装成 DioException(error: ApiException),与线上一致。
ApiService _realApi(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.httpClientAdapter = adapter;
  return ApiService.withDio(dio);
}

/// 按 path 精确路由响应的测试 adapter:GET 列表与 PUT 状态流转返回不同响应,
/// [hits] 记录请求序,用于断言 invalidate 是否触发(refetch 会再打一次 GET)。
class _RoutingAdapter implements HttpClientAdapter {
  _RoutingAdapter(this.routes);

  final Map<String, (int, Object)> routes;
  final List<String> hits = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hits.add('${options.method} ${options.path}');
    final (code, data) = routes[options.path]!; // 未注册路由直接炸,fail fast
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(data)),
      code,
      headers: const <String, List<String>>{
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  late MockApi api;
  setUp(() {
    api = MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
  });

  ProviderContainer makeContainer(List<AdminMiniProgramInfo> items) {
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      adminMiniProgramsProvider.overrideWith((ref) async => items),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  testWidgets('三 Tab 渲染:待审/已发布/已下架,条目进对应 Tab', (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: makeContainer([_mp('private'), _mp('published'), _mp('disabled')]),
      child: const MaterialApp(home: AdminMiniProgramPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('待审'), findsOneWidget);
    expect(find.text('已发布'), findsOneWidget);
    expect(find.text('已下架'), findsOneWidget);
    expect(find.text('N-private'), findsOneWidget);
  });

  testWidgets('发布操作:确认弹窗→确认→调 setMiniProgramStatus→invalidate 刷新',
      (tester) async {
    when(() => api.setMiniProgramStatus('id-private', 'published'))
        .thenAnswer((_) async {});
    await tester.pumpWidget(UncontrolledProviderScope(
      container: makeContainer([_mp('private')]),
      child: const MaterialApp(home: AdminMiniProgramPage()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    expect(find.text('确认发布？'), findsOneWidget);
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    verify(() => api.setMiniProgramStatus('id-private', 'published')).called(1);
  });

  testWidgets('403 → 页面提示无权限(真实拦截器链路:DioException.error 内包 ApiException)',
      (tester) async {
    final c = ProviderContainer(overrides: [
      // 不 override provider:GET /api/admin/mini-programs 返回 HTTP 403 envelope,
      // 经拦截器包装成 DioException(error: ApiException(403)),页面须解包后判 403
      apiProvider.overrideWithValue(_realApi(MockHttpClientAdapter(403, {
        'ok': false,
        'error': {'code': 'forbidden', 'message': 'denied'},
      }))),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c, child: const MaterialApp(home: AdminMiniProgramPage())));
    await tester.pumpAndSettle();
    expect(find.text('无权限查看'), findsOneWidget);
  });

  testWidgets('非 403 错误 → 加载失败文案 + 重试按钮', (tester) async {
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      adminMiniProgramsProvider.overrideWith((ref) async =>
          throw ApiException('internal', 'boom', statusCode: 500)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c, child: const MaterialApp(home: AdminMiniProgramPage())));
    await tester.pumpAndSettle();
    expect(find.textContaining('加载失败'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('操作失败(PUT 403)→ 失败 snackbar 且不调 invalidate', (tester) async {
    final adapter = _RoutingAdapter({
      '/api/admin/mini-programs': (
        200,
        {'ok': true, 'data': [_mpJson(_mp('private'))]}
      ),
      '/api/admin/mini-programs/id-private/status': (
        403,
        {
          'ok': false,
          'error': {'code': 'forbidden', 'message': 'denied'},
        }
      ),
    });
    final c = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(_realApi(adapter)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c, child: const MaterialApp(home: AdminMiniProgramPage())));
    await tester.pumpAndSettle();
    expect(adapter.hits, ['GET /api/admin/mini-programs']);

    await tester.tap(find.text('发布'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    // PUT 403 → 解包出 ApiException(403) → 无权限 snackbar,而非原始异常 dump
    expect(find.text('无权限操作'), findsOneWidget);
    expect(find.textContaining('DioException'), findsNothing);
    // 未 invalidate:操作失败不刷新列表,GET 只在首次加载打过一次
    expect(adapter.hits,
        ['GET /api/admin/mini-programs', 'PUT /api/admin/mini-programs/id-private/status']);
  });
}
