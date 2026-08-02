import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:app/utils/gallery_image.dart';
import 'package:app/models/message.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

/// 假 HttpClientAdapter：固定返回给定状态码和字节。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({required this.statusCode, required this.body});
  final int statusCode;
  final List<int> body;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final stream = Stream<Uint8List>.fromIterable([Uint8List.fromList(body)]);
    return ResponseBody(stream, statusCode, headers: {
      Headers.contentTypeHeader: ['application/octet-stream'],
    });
  }
}

void main() {
  group('extractInternalImageIds', () {
    test('提取单张内部图片 fileId', () {
      const md = '看这张 ![猫](/api/files/abc123)';
      expect(extractInternalImageIds(md), ['abc123']);
    });

    test('提取多张内部图片，保持出现顺序', () {
      const md = '![a](/api/files/id1) 和 ![b](/api/files/id2)';
      expect(extractInternalImageIds(md), ['id1', 'id2']);
    });

    test('忽略外部 URL，只保留内部', () {
      const md = '![外](https://evil.com/x.png) ![内](/api/files/keep)';
      expect(extractInternalImageIds(md), ['keep']);
    });

    test('空文本/null 返回空列表', () {
      expect(extractInternalImageIds(''), <String>[]);
      expect(extractInternalImageIds(null), <String>[]);
    });
  });

  group('collectConversationImages', () {
    ChatMessage msg(String id, String msgType, Map<String, dynamic> data) =>
        ChatMessage(
          id: id,
          conversationId: 'conv1',
          senderType: 'agent',
          senderId: 'a1',
          content: {'msg_type': msgType, 'data': data},
          createdAt: DateTime(2026, 6, 25),
        );

    test('混合 image + markdown 消息，收集去重并按时间正序(index0=最旧)', () {
      // messages 是 newest first 顺序（m1 最新），收集后反转：index0=最旧。
      final messages = [
        msg('m1', 'image', {'file_id': 'img1'}),
        msg('m2', 'text', {'text': 'hello'}), // 非 image/markdown，跳过
        msg('m3', 'markdown', {'text': '![x](/api/files/img2)'}),
        msg('m4', 'image', {'file_id': 'img1'}), // 重复 fileId，去重
      ];
      final result = collectConversationImages(messages, 'https://h', 'tok');
      // 反转后：最旧的 img2 在前，img1 在后
      expect(result.map((g) => g.fileId), ['img2', 'img1']);
      expect(result[0].heroTag, 'gallery_img2');
      expect(result[0].url, 'https://h/api/files/img2');
      expect(result[0].headers['Authorization'], 'Bearer tok');
    });

    test('空消息列表返回空', () {
      expect(
          collectConversationImages([], 'https://h', 'tok'), <GalleryImage>[]);
    });
  });

  group('saveToGallery', () {
    // gal 插件的 method channel（gal 2.3.2 用 'gal'）
    const galChannel = MethodChannel('gal');

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
    });

    tearDown(() {
      // 清理 gal channel mock
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(galChannel, null);
    });

    test('鉴权下载成功 + gal putImageBytes 成功 → SaveResult.success', () async {
      // mock gal channel：requestAccess 返回 true，putImageBytes 返回成功
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(galChannel, (call) async {
        switch (call.method) {
          case 'requestAccess':
            return true;
          case 'putImageBytes':
            return null;
          default:
            return null;
        }
      });

      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(
        statusCode: 200,
        body: [0x89, 0x50, 0x4E, 0x47], // 假 PNG 字节
      );

      final image = GalleryImage(
        url: 'https://example.com/api/files/abc',
        fileId: 'abc',
        headers: const {'Authorization': 'Bearer test-token'},
      );

      final result = await saveToGallery(image, dio: dio);
      expect(result, SaveResult.success);
    });

    test('dio 下载失败（404，在 gal 调用前）→ SaveResult.failed', () async {
      // 下载在 gal 之前失败，无需 gal mock
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(statusCode: 404, body: []);

      final image = GalleryImage(
        url: 'https://example.com/api/files/abc',
        fileId: 'abc',
        headers: const {},
      );

      final result = await saveToGallery(image, dio: dio);
      expect(result, SaveResult.failed);
    });

    test('gal 写入抛异常 → SaveResult.failed（不抛到调用方）', () async {
      // mock gal channel 抛 PlatformException（模拟 Android 6-9 权限被拒等）
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(galChannel, (call) async {
        throw PlatformException(code: 'ACCESS_DENIED', message: '写入失败');
      });

      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter(
        statusCode: 200,
        body: [0x89, 0x50, 0x4E, 0x47],
      );

      final image = GalleryImage(
        url: 'https://example.com/api/files/abc',
        fileId: 'abc',
        headers: const {},
      );

      final result = await saveToGallery(image, dio: dio);
      expect(result, SaveResult.failed);
    });
  });
}
