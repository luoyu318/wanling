import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/message.dart';
import 'package:app/services/api_service.dart';

import '../helpers/mock_adapter.dart';

/// 构造 ApiService，MockAdapter 用 envelope 包装 data。
/// 拦截器剥 envelope 后业务层拿到 data 部分。
ApiService _api(dynamic data) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  final api = ApiService.withDio(dio);
  dio.httpClientAdapter = CapturingMockAdapter(
    200,
    {'ok': true, 'data': data},
  );
  return api;
}

/// 构造 ApiService 并 stub 一个 4xx/5xx envelope 错误响应。
ApiService _apiError(int statusCode, String code, String message) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  final api = ApiService.withDio(dio);
  dio.httpClientAdapter = MockHttpClientAdapter(
    statusCode,
    {
      'ok': false,
      'error': {'code': code, 'message': message},
    },
  );
  return api;
}

/// ChatMessage fixture(字段对齐 server model.Message json tag +
/// SanitizeForClient 后的 content 形态)。
Map<String, dynamic> _msgJson(String id, {String? createdAt}) {
  return <String, dynamic>{
    'id': id,
    'conversation_id': 'c1',
    'sender_type': 'user',
    'sender_id': 'u1',
    'content': {'msg_type': 'text', 'data': {'text': 'msg-$id'}},
    'created_at': createdAt ?? '2026-07-04T10:00:00Z',
  };
}

void main() {
  group('getMessageContext', () {
    test('happy path: 解析 target + before + after', () async {
      // before 时间倒序(最新在前),after 时间正序(最老在前)
      final api = _api({
        'target': _msgJson('m5', createdAt: '2026-07-04T10:05:00Z'),
        'before': [
          _msgJson('m4', createdAt: '2026-07-04T10:04:00Z'),
          _msgJson('m3', createdAt: '2026-07-04T10:03:00Z'),
        ],
        'after': [
          _msgJson('m6', createdAt: '2026-07-04T10:06:00Z'),
          _msgJson('m7', createdAt: '2026-07-04T10:07:00Z'),
        ],
      });

      final result = await api.getMessageContext('m5', before: 2, after: 2);

      expect(result, isA<MessageContext>());
      expect(result.target.id, 'm5');
      expect(result.target.conversationId, 'c1');
      expect(result.before, isA<List<ChatMessage>>());
      expect(result.before.length, 2);
      expect(result.before[0].id, 'm4');
      expect(result.before[1].id, 'm3');
      expect(result.after, isA<List<ChatMessage>>());
      expect(result.after.length, 2);
      expect(result.after[0].id, 'm6');
      expect(result.after[1].id, 'm7');
    });

    test('before/after 缺失时返空 list(防御性)', () async {
      // server 实际总返非 nil 数组,但 client 兜底防御
      final api = _api({
        'target': _msgJson('m1'),
        // 故意缺 before / after 字段
      });

      final result = await api.getMessageContext('m1');

      expect(result.before, isEmpty);
      expect(result.after, isEmpty);
    });

    test('404 not_found → MessageNotFoundException', () async {
      final api = _apiError(404, 'not_found', '消息不存在');
      await expectLater(
        api.getMessageContext('missing'),
        throwsA(isA<MessageNotFoundException>()),
      );
    });

    test('403 forbidden → NoAccessException', () async {
      final api = _apiError(403, 'forbidden', '无权操作该会话消息');
      await expectLater(
        api.getMessageContext('m1'),
        throwsA(isA<NoAccessException>()),
      );
    });

    test('其他 envelope error(如 internal_error)原样抛 DioException', () async {
      final api = _apiError(500, 'internal_error', '查询失败');
      await expectLater(
        api.getMessageContext('m1'),
        throwsA(isA<DioException>()),
      );
    });

    test('passes before/after as query parameters + 正确 path', () async {
      final api = _api({
        'target': _msgJson('m1'),
        'before': <Map<String, dynamic>>[],
        'after': <Map<String, dynamic>>[],
      });

      await api.getMessageContext('m1', before: 5, after: 5);

      final captured =
          (api.dio.httpClientAdapter as CapturingMockAdapter).captured;
      expect(captured.path, '/api/messages/m1/context');
      expect(captured.method, 'GET');
      expect(captured.queryParameters['before'], 5);
      expect(captured.queryParameters['after'], 5);
    });

    test('before/after 默认值 10', () async {
      final api = _api({
        'target': _msgJson('m1'),
        'before': <Map<String, dynamic>>[],
        'after': <Map<String, dynamic>>[],
      });

      await api.getMessageContext('m1');

      final captured =
          (api.dio.httpClientAdapter as CapturingMockAdapter).captured;
      expect(captured.queryParameters['before'], 10);
      expect(captured.queryParameters['after'], 10);
    });
  });

  group('MessageNotFoundException', () {
    test('是 Exception 子类,可正常构造', () {
      const exc = MessageNotFoundException();
      expect(exc, isA<Exception>());
    });
  });

  group('NoAccessException', () {
    test('是 Exception 子类,可正常构造', () {
      const exc = NoAccessException();
      expect(exc, isA<Exception>());
    });
  });

  group('MessageContext', () {
    test('字段持有 target + before + after', () {
      final target = ChatMessage(
        id: 't',
        conversationId: 'c',
        senderType: 'user',
        senderId: 'u',
        content: {'msg_type': 'text', 'data': {'text': 'x'}},
        createdAt: DateTime.utc(2026, 7, 4, 10),
      );
      final ctx = MessageContext(target: target, before: [], after: []);
      expect(ctx.target.id, 't');
      expect(ctx.before, isEmpty);
      expect(ctx.after, isEmpty);
    });
  });
}
