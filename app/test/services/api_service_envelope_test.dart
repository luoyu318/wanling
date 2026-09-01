import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/api_response.dart';

import '../helpers/mock_adapter.dart';

void main() {
  late ApiService api;

  setUp(() {
    api = ApiService.withDio(Dio(BaseOptions(baseUrl: 'http://test')));
  });

  test('成功响应剥 envelope 返回 data', () async {
    api.dio.httpClientAdapter = CapturingMockAdapter(
      200,
      {'ok': true, 'data': {'id': 'abc'}},
    );
    final res = await api.dio.get('/test');
    expect(res.data, {'id': 'abc'});
  });

  test('ok=false 响应通过 DioException.error 抛 ApiException', () async {
    api.dio.httpClientAdapter = CapturingMockAdapter(
      200,
      {
        'ok': false,
        'error': {'code': 'not_found', 'message': '不存在'},
      },
    );
    expect(
      () => api.dio.get('/test'),
      throwsA(isA<DioException>()
          .having((e) => e.error, 'error', isA<ApiException>()
              .having((ae) => ae.code, 'code', 'not_found')
              .having((ae) => ae.message, 'message', '不存在'))),
    );
  });

  test('4xx body 含 envelope error 通过 DioException.error 抛带 code 的 ApiException', () async {
    api.dio.httpClientAdapter = MockHttpClientAdapter(
      403,
      {
        'ok': false,
        'error': {'code': 'forbidden', 'message': '无权限'},
      },
    );
    expect(
      () => api.dio.get('/test'),
      throwsA(isA<DioException>()
          .having((e) => e.error, 'error', isA<ApiException>()
              .having((ae) => ae.code, 'code', 'forbidden')
              .having((ae) => ae.message, 'message', '无权限')
              .having((ae) => ae.statusCode, 'statusCode', 403))),
    );
  });

  test('ok 字段缺失透传(非 envelope)', () async {
    api.dio.httpClientAdapter = CapturingMockAdapter(
      200,
      {'raw_field': 'x'},
    );
    final res = await api.dio.get('/test');
    expect(res.data, {'raw_field': 'x'});
  });

  test('binary 响应透传(非 Map)', () async {
    // dio 默认 JSON decode,只能拿到 Map/String/List;
    // 这里用 responseType: bytes 模拟 binary 下载场景,拦截器应透传不动。
    api.dio.httpClientAdapter = MockHttpClientAdapter(
      200,
      {'ok': true, 'data': [1, 2, 3]},
    );
    final res = await api.dio.get(
      '/file',
      options: Options(responseType: ResponseType.bytes),
    );
    // bytes 模式下 dio 返回 Uint8List,不会是 Map<String, dynamic>
    expect(res.data, isNot(isA<Map<String, dynamic>>()));
  });

  test('getMiniPrograms 拦截器剥 envelope 后按裸 list 解析', () async {
    // mock 返回服务端原始 envelope;getMiniPrograms 必须在拦截器剥离后的
    // res.data(List)上解析,若再解一次 envelope(data['data'])会抛 TypeError。
    api.dio.httpClientAdapter = MockHttpClientAdapter(
      200,
      {
        'ok': true,
        'data': [
          {
            'id': 'id-1',
            'appid': 'a',
            'owner_id': 'o',
            'name': 'A',
            'version': 1,
            'status': 'published',
            'sha256': 'x',
            'size': 1,
          },
        ],
      },
    );
    final list = await api.getMiniPrograms();
    expect(list, hasLength(1));
    expect(list.first.appid, 'a');
  });

  test('getSigningPublicKey 拦截器剥 envelope 后按裸 payload 解析 public_key', () async {
    // mock 返回服务端原始 envelope;必须在拦截器剥离后的 res.data(Map)上解析,
    // 若再解一次 envelope(data['data'])会抛 TypeError。
    api.dio.httpClientAdapter = MockHttpClientAdapter(
      200,
      {
        'ok': true,
        'data': {'public_key': 'aabbccdd'},
      },
    );
    expect(await api.getSigningPublicKey(), 'aabbccdd');
  });

  test('getSigningPublicKey public_key 缺失 fail fast 抛错', () async {
    api.dio.httpClientAdapter = MockHttpClientAdapter(
      200,
      {
        'ok': true,
        'data': {'unexpected': 'x'},
      },
    );
    expect(() => api.getSigningPublicKey(), throwsA(isA<TypeError>()));
  });

  test('ok=false 缺 error 字段兜底 internal_error', () async {
    api.dio.httpClientAdapter = MockHttpClientAdapter(
      200,
      {'ok': false},
    );
    expect(
      () => api.dio.get('/test'),
      throwsA(isA<DioException>()
          .having((e) => e.error, 'error', isA<ApiException>()
              .having((ae) => ae.code, 'code', 'internal_error'))),
    );
  });
}
