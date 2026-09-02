// proxyApiResource 纯函数回归测试 —— 钉住虚拟域 /api/ 资源代理语义。
// 小程序内头像等宿主资源以相对路径引用时解析到虚拟域,由本代理带登录态回源;
// 非 /api/ 路径返回 null 交还本地包文件逻辑。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/pages/mini_program_page.dart';
import 'package:wanling_core/services/api_service.dart';

/// 返回固定字节与 Content-Type 的 mock adapter;[throwOn] 模拟上游请求失败。
class BytesMockAdapter implements HttpClientAdapter {
  BytesMockAdapter({
    this.bytes = const [],
    this.contentType = 'image/png',
    this.throwOn = false,
  });

  final List<int> bytes;
  final String contentType;
  final bool throwOn;
  RequestOptions? captured;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (throwOn) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        error: 'upstream boom',
      );
    }
    captured = options;
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: <String, List<String>>{
        Headers.contentTypeHeader: [contentType],
      },
    );
  }
}

ApiService apiWith(BytesMockAdapter adapter) =>
    ApiService.withDio(Dio()..httpClientAdapter = adapter);

void main() {
  final avatarUri =
      Uri.parse('https://a1.u1.mini.wanling.local/api/files/av.png?q=1');

  test('非 /api/ 路径 → 返回 null 交还本地包文件逻辑,不发网络', () async {
    final adapter = BytesMockAdapter();
    final r = await proxyApiResource(
        apiWith(adapter),
        Uri.parse('https://a1.u1.mini.wanling.local/index.html'),
        method: 'GET');
    expect(r, isNull);
    expect(adapter.captured, isNull);
  });

  test('非 GET → 405 且不发网络', () async {
    final adapter = BytesMockAdapter();
    final r = await proxyApiResource(apiWith(adapter), avatarUri,
        method: 'POST');
    expect(r, isNotNull);
    expect(r!.statusCode, 405);
    expect(adapter.captured, isNull);
  });

  test('GET /api/ → 代理回源字节与 Content-Type,透传路径与 query', () async {
    final adapter =
        BytesMockAdapter(bytes: utf8.encode('png-bytes'), contentType: 'image/png');
    final r = await proxyApiResource(apiWith(adapter), avatarUri);
    expect(r, isNotNull);
    expect(r!.contentType, 'image/png');
    expect(r.data, isA<Uint8List>());
    expect(String.fromCharCodes(r.data!), 'png-bytes');
    expect(adapter.captured!.path, '/api/files/av.png');
    expect(adapter.captured!.queryParameters, {'q': '1'});
  });

  test('上游请求失败 → 502', () async {
    final r = await proxyApiResource(
        apiWith(BytesMockAdapter(throwOn: true)), avatarUri);
    expect(r, isNotNull);
    expect(r!.statusCode, 502);
  });

  test('/api/ 点段归一化后回源(防路径混淆;固定 baseUrl 目标,无开放代理面)', () async {
    final adapter = BytesMockAdapter();
    final r = await proxyApiResource(
        apiWith(adapter),
        Uri.parse(
            'https://a1.u1.mini.wanling.local/api/files/../files/av.png'));
    expect(r, isNotNull);
    expect(adapter.captured!.path, '/api/files/av.png');
  });

  test('点段逃逸(/api/%2e%2e/secret)不构成 /api/ 代理面 → null 且不回源', () async {
    // Uri.parse 解析期即消解点段(含编码 %2e%2e),path 变为 /secret 不满足
    // /api/ 前缀 → null 交还原逻辑(zip-slip 防护兜底),函数内归一化 + 前缀
    // 复检为纵深防御,防手工构造的未消解点段 Uri 混淆回源目标
    final adapter = BytesMockAdapter();
    final r = await proxyApiResource(apiWith(adapter),
        Uri.parse('https://a1.u1.mini.wanling.local/api/%2e%2e/secret'));
    expect(r, isNull);
    expect(adapter.captured, isNull);
  });
}
