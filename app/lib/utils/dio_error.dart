import 'package:dio/dio.dart' show DioException, DioExceptionType;

import 'package:wanling_core/services/api_response.dart' show ApiException;

/// 从异常中提取用户可读的错误信息。
///
/// 优先级:
/// 1. ApiException (envelope 化后, DioException.error 已被拦截器包成 ApiException,
///    直接取 message)
/// 2. envelope body error.message (兼容拦截器未触发路径, 如 binary 响应)
/// 3. 旧形态 data['error'] (String)
/// 4. 网络层错误 (无法连接 / 超时) 给固定文案
/// 5. fallback: toString 兜底
String extractDioErrorMessage(
  Object e, {
  String fallback = '操作失败',
  String networkErrorMessage = '无法连接服务器，请检查地址或网络',
}) {
  if (e is DioException) {
    // envelope 化: 拦截器把 ApiException 包到 e.error
    final cause = e.error;
    if (cause is ApiException) {
      return cause.message;
    }
    final data = e.response?.data;
    if (data is Map) {
      // 新 envelope: {ok:false, error:{code, message}}
      final err = data['error'];
      if (err is Map && err['message'] is String) {
        return err['message'] as String;
      }
      // 老形态: {error: "..."} (兼容过渡)
      if (err is String) {
        return err;
      }
    }
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return networkErrorMessage;
    }
  }
  if (e is ApiException) {
    return e.message;
  }
  return '$fallback: $e';
}
