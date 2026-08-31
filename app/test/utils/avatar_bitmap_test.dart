import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:app/utils/avatar_bitmap.dart';

/// 按序返回预置响应的 mock adapter(第 n 次请求取第 n 项,耗尽后重复最后一项)。
class _QueueAdapter implements HttpClientAdapter {
  _QueueAdapter(this._responses);

  final List<ResponseBody> _responses;
  int _calls = 0;
  final List<RequestOptions> captured = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    final i = _calls < _responses.length ? _calls : _responses.length - 1;
    _calls++;
    return _responses[i];
  }

  @override
  void close({bool force = false}) {}
}

/// 生成最小合法 PNG bytes(供下载成功路径解码)。
Uint8List _png() => Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));

ResponseBody _resp(int code, [List<int>? body]) => ResponseBody.fromBytes(
    body ?? utf8.encode(jsonEncode({'error': 'x'})),
    code,
    headers: const <String, List<String>>{
      'content-type': ['application/json'],
    });

void main() {
  group('loadAvatarBitmap', () {
    test('avatarUrl 为空时返回首字母色块 PNG bytes, isRealAvatar=false', () async {
      final (bytes, isReal) = await loadAvatarBitmap(
        agentId: 'agent-1',
        name: '白羽',
        avatarUrl: null,
        baseUrl: 'http://localhost:18008',
        httpHeaders: {},
      );
      // 返回非空 PNG(8 字节 PNG signature 开头)
      expect(bytes, isNotEmpty);
      expect(bytes[0], 0x89);
      expect(bytes[1], 0x50); // 'P'
      expect(bytes[2], 0x4E); // 'N'
      expect(bytes[3], 0x47); // 'G'
      expect(isReal, isFalse);
    });

    test('同名 agent 多次调用色块颜色一致(hash 稳定)', () async {
      final (b1, r1) = await loadAvatarBitmap(
        agentId: 'a',
        name: '白羽',
        avatarUrl: null,
        baseUrl: '',
        httpHeaders: {},
      );
      final (b2, r2) = await loadAvatarBitmap(
        agentId: 'b',
        name: '白羽',
        avatarUrl: null,
        baseUrl: '',
        httpHeaders: {},
      );
      expect(r1, isFalse);
      expect(r2, isFalse);
      expect(b1, equals(b2));
    });

    test('下载成功返回真头像, isRealAvatar=true', () async {
      final dio = Dio()
        ..httpClientAdapter = _QueueAdapter([_resp(200, _png())]);
      final (bytes, isReal) = await loadAvatarBitmap(
        agentId: 'agent-real',
        name: '灵仔',
        avatarUrl: '/api/files/abc',
        baseUrl: 'http://localhost:18008',
        httpHeaders: {'Authorization': 'Bearer old'},
        dioOverride: dio,
      );
      expect(isReal, isTrue);
      expect(bytes[0], 0x89); // PNG
      // 下载相对路径拼接 baseUrl
      expect(dio.httpClientAdapter is _QueueAdapter, isTrue);
      final captured =
          (dio.httpClientAdapter as _QueueAdapter).captured.single;
      expect(captured.uri.toString(), 'http://localhost:18008/api/files/abc');
    });

    test('401 时调 onUnauthorized 换新 token 重试一次,成功返回真头像', () async {
      final dio = Dio()
        ..httpClientAdapter = _QueueAdapter([_resp(401), _resp(200, _png())]);
      String? refreshedWith;
      final (bytes, isReal) = await loadAvatarBitmap(
        agentId: 'agent-401',
        name: '黑羽',
        avatarUrl: '/api/files/abc',
        baseUrl: 'http://localhost:18008',
        httpHeaders: {'Authorization': 'Bearer stale'},
        onUnauthorized: () async {
          refreshedWith = 'stale';
          return 'fresh';
        },
        dioOverride: dio,
      );
      expect(isReal, isTrue);
      expect(bytes[0], 0x89); // PNG
      expect(refreshedWith, 'stale');
      final adapter = dio.httpClientAdapter as _QueueAdapter;
      expect(adapter.captured.length, 2, reason: '401 后应恰好重试一次');
      expect(adapter.captured[0].headers['Authorization'], 'Bearer stale');
      expect(adapter.captured[1].headers['Authorization'], 'Bearer fresh');
    });

    test('401 且 onUnauthorized 返回 null(刷新失败)时兜底色块', () async {
      final dio = Dio()..httpClientAdapter = _QueueAdapter([_resp(401)]);
      final (bytes, isReal) = await loadAvatarBitmap(
        agentId: 'agent-401-fail',
        name: '黑羽',
        avatarUrl: '/api/files/abc',
        baseUrl: 'http://localhost:18008',
        httpHeaders: {'Authorization': 'Bearer stale'},
        onUnauthorized: () async => null,
        dioOverride: dio,
      );
      expect(isReal, isFalse);
      expect(bytes[0], 0x89); // PNG 色块
      expect((dio.httpClientAdapter as _QueueAdapter).captured.length, 1,
          reason: '刷新失败不重试');
    });

    test('401 且未传 onUnauthorized 时直接兜底色块,不重试', () async {
      final dio = Dio()..httpClientAdapter = _QueueAdapter([_resp(401)]);
      final (_, isReal) = await loadAvatarBitmap(
        agentId: 'agent-401-nocb',
        name: '黑羽',
        avatarUrl: '/api/files/abc',
        baseUrl: 'http://localhost:18008',
        httpHeaders: {'Authorization': 'Bearer stale'},
        dioOverride: dio,
      );
      expect(isReal, isFalse);
      expect((dio.httpClientAdapter as _QueueAdapter).captured.length, 1);
    });

    test('非 401 失败(如 404)直接兜底色块,不触发 onUnauthorized', () async {
      var refreshCalled = false;
      final dio = Dio()..httpClientAdapter = _QueueAdapter([_resp(404)]);
      final (_, isReal) = await loadAvatarBitmap(
        agentId: 'agent-404',
        name: '黑羽',
        avatarUrl: '/api/files/abc',
        baseUrl: 'http://localhost:18008',
        httpHeaders: {'Authorization': 'Bearer x'},
        onUnauthorized: () async {
          refreshCalled = true;
          return 'fresh';
        },
        dioOverride: dio,
      );
      expect(isReal, isFalse);
      expect(refreshCalled, isFalse, reason: '仅 401 才触发 token 刷新');
    });

    test('下载超时常量为 15s', () {
      expect(kAvatarDownloadTimeout, const Duration(seconds: 15));
    });
  });

  group('圆角判定 _isInsideRoundedRect', () {
    // 锁死圆角形状正确性(防回归:C1 bug 曾把圆角误判成方切角)
    test('48x48 r=9:角上像素透明,圆弧中段不透明,直边中点不透明', () {
      const w = 48, h = 48, r = 9;
      // 四个角的外角(应被切掉,透明)
      expect(isInsideRoundedRectForTest(0, 0, w, h, r), isFalse); // 左上外角
      expect(isInsideRoundedRectForTest(0, h - 1, w, h, r), isFalse); // 左下外角
      expect(isInsideRoundedRectForTest(w - 1, 0, w, h, r), isFalse); // 右上外角
      expect(isInsideRoundedRectForTest(w - 1, h - 1, w, h, r), isFalse); // 右下外角

      // 四条直边中点(应不透明,在中心十字区)
      expect(isInsideRoundedRectForTest(w ~/ 2, 0, w, h, r), isTrue); // 顶边中点
      expect(isInsideRoundedRectForTest(w ~/ 2, h - 1, w, h, r), isTrue); // 底边中点
      expect(isInsideRoundedRectForTest(0, h ~/ 2, w, h, r), isTrue); // 左边中点
      expect(isInsideRoundedRectForTest(w - 1, h ~/ 2, w, h, r), isTrue); // 右边中点

      // 正中心(恒不透明)
      expect(isInsideRoundedRectForTest(w ~/ 2, h ~/ 2, w, h, r), isTrue);

      // 圆心点(应不透明,距圆心 0)
      expect(isInsideRoundedRectForTest(r, r, w, h, r), isTrue); // 左上圆心
    });

    test('角方框内但距圆心<=r的点不透明(圆弧内)', () {
      const w = 48, h = 48, r = 9;
      // 左上角方框内,距圆心(r,r) 距离 = r 的点(圆弧上)
      // (r-1, r) 距离² = 1 <= r²,应不透明
      expect(isInsideRoundedRectForTest(r - 1, r, w, h, r), isTrue);
    });
  });
}
