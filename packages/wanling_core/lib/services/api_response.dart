/// REST envelope 错误。后端返 `{ok: false, error: {code, message}}` 时
/// 由 ApiService 拦截器抛出。调用方可 try/catch ApiException 按 code 分流。
class ApiException implements Exception {
  final String code;
  final String message;
  final int? statusCode;

  ApiException(this.code, this.message, {this.statusCode});

  @override
  String toString() => 'ApiException($code): $message';
}
