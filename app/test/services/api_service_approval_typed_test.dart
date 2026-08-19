import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/approval.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/api_response.dart';

import '../helpers/mock_adapter.dart';

void main() {
  test('getApproval 成功返 Approval', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    final api = ApiService.withDio(dio);
    dio.httpClientAdapter = CapturingMockAdapter(200, {
      'ok': true,
      'data': {
        'id': 'ap1',
        'message_id': 'm1',
        'conversation_id': 'c1',
        'initiator_type': 'agent',
        'initiator_id': 'ag1',
        'card_type': 'command',
        'state': 'pending',
        'actions': [],
        'expires_at': '2026-07-04T10:00:00Z',
        'session_key': 'sk1',
        'created_at': '2026-07-04T09:00:00Z',
      },
    });
    final approval = await api.getApproval('ap1');
    expect(approval, isA<Approval>());
    expect(approval!.id, 'ap1');
    expect(approval.initiatorType, 'agent');
  });

  test('getApproval 404 返 null', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    final api = ApiService.withDio(dio);
    dio.httpClientAdapter = CapturingMockAdapter(404, {
      'ok': false,
      'error': {'code': 'not_found', 'message': '不存在'},
    });
    final approval = await api.getApproval('missing');
    expect(approval, isNull);
  });

  test('getApproval 其他错误重抛', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    final api = ApiService.withDio(dio);
    dio.httpClientAdapter = CapturingMockAdapter(403, {
      'ok': false,
      'error': {'code': 'forbidden', 'message': '无权限'},
    });
    // 拦截器把 4xx envelope 包成 DioException(error: ApiException)，业务层 rethrow 后看到的是 DioException
    expect(
      () => api.getApproval('ap1'),
      throwsA(
        isA<DioException>()
            .having((e) => e.error, 'error', isA<ApiException>()
                .having((ae) => ae.code, 'code', 'forbidden')),
      ),
    );
  });
}
