import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wanling_core/services/api_response.dart';
import 'package:app/utils/dio_error.dart';

void main() {
  group('extractDioErrorMessage', () {
    test('envelope ApiException (e.error 包成 ApiException)', () {
      final ex = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 401,
          data: const {
            'ok': false,
            'error': {'code': 'unauthorized', 'message': '用户名或密码错误'},
          },
        ),
        error: ApiException('unauthorized', '用户名或密码错误', statusCode: 401),
      );
      expect(extractDioErrorMessage(ex), '用户名或密码错误');
    });

    test('裸 ApiException (无 DioException 包装)', () {
      final ex = ApiException('bad_request', '参数错误', statusCode: 400);
      expect(extractDioErrorMessage(ex), '参数错误');
    });

    test('envelope body 但 e.error 未被拦截器替换', () {
      final ex = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 500,
          data: const {
            'ok': false,
            'error': {'code': 'internal_error', 'message': '查询失败'},
          },
        ),
      );
      expect(extractDioErrorMessage(ex), '查询失败');
    });

    test('老形态 data[error] 字符串', () {
      final ex = DioException(
        requestOptions: RequestOptions(path: '/x'),
        response: Response(
          requestOptions: RequestOptions(path: '/x'),
          statusCode: 500,
          data: const {'error': '老接口错误'},
        ),
      );
      expect(extractDioErrorMessage(ex), '老接口错误');
    });

    test('网络层错误给固定文案', () {
      final ex = DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: DioExceptionType.connectionError,
      );
      expect(extractDioErrorMessage(ex), '无法连接服务器，请检查地址或网络');
    });

    test('其他异常 toString 兜底', () {
      expect(extractDioErrorMessage(Exception('boom')), contains('boom'));
    });
  });
}
