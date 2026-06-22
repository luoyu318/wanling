import 'package:dio/dio.dart' show DioException, DioExceptionType;

/// 从异常中提取用户可读的错误信息。
///
/// Dio 服务端错误通常形如 `{error: "用户名或密码错误"}`，这里提取 error 字段；
/// 网络层错误（无法连接、超时）给固定文案；其他异常 toString 兜底。
String extractDioErrorMessage(
  Object e, {
  String fallback = '操作失败',
  String networkErrorMessage = '无法连接服务器，请检查地址或网络',
}) {
  if (e is DioException) {
    final data = e.response?.data;
    if (data is Map && data['error'] is String) {
      return data['error'] as String;
    }
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return networkErrorMessage;
    }
  }
  return '$fallback: $e';
}
