import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/register_result.dart';

void main() {
  test('fromJson 解析 token', () {
    final result = RegisterResult.fromJson({'token': 'jwt-yyy'});
    expect(result.token, 'jwt-yyy');
  });

  test('缺少 token 抛异常（fail fast）', () {
    expect(
      () => RegisterResult.fromJson({}),
      throwsA(isA<TypeError>()),
    );
  });
}
