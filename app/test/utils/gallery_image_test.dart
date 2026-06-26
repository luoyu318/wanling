import 'package:flutter_test/flutter_test.dart';
import 'package:app/utils/gallery_image.dart';
import 'package:app/models/message.dart';

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
}
