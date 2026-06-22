import 'dart:convert';
import 'package:dio/dio.dart';

/// 按 (statusCode, data) 直接构造响应的测试用 mock adapter。
/// 不捕获 RequestOptions，适用于只需返回固定响应的场景。
class MockHttpClientAdapter implements HttpClientAdapter {
  MockHttpClientAdapter(this.statusCode, this.data);

  final int statusCode;
  final dynamic data;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(data)),
      statusCode,
      headers: const <String, List<String>>{
        'content-type': ['application/json'],
      },
    );
  }
}

/// 捕获 RequestOptions 的测试用 mock adapter，按 (statusCode, data) 构造响应。
/// 在外部可读取 [captured] 验证 path / headers / body 等请求参数。
/// 即使测试用例不需要 capture，使用本类也无副作用（captured 字段 unused 即可）。
class CapturingMockAdapter implements HttpClientAdapter {
  CapturingMockAdapter(this.statusCode, this.data);

  final int statusCode;
  final dynamic data;
  late RequestOptions captured;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured = options;
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(data)),
      statusCode,
      headers: const <String, List<String>>{
        'content-type': ['application/json'],
      },
    );
  }
}
