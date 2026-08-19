import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/services/api_response.dart';

void main() {
  group('ApiException', () {
    test('构造 + toString', () {
      final e = ApiException('not_found', '资源不存在', statusCode: 404);
      expect(e.code, 'not_found');
      expect(e.message, '资源不存在');
      expect(e.statusCode, 404);
      expect(e.toString(), 'ApiException(not_found): 资源不存在');
    });

    test('statusCode 可空', () {
      final e = ApiException('internal_error', '失败');
      expect(e.statusCode, isNull);
    });
  });
}
