import 'package:wanling_core/models/file_content.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileContent.fromJson', () {
    test('文本内容', () {
      final c = FileContent.fromJson({
        'path': 'README.md',
        'type': 'text',
        'mime': 'text/markdown',
        'size': 100,
        'content': 'hello',
        'truncated': false,
      });
      expect(c.path, 'README.md');
      expect(c.type, 'text');
      expect(c.mime, 'text/markdown');
      expect(c.size, 100);
      expect(c.content, 'hello');
      expect(c.contentBase64, isNull);
      expect(c.truncated, isFalse);
    });

    test('图片内容', () {
      final c = FileContent.fromJson({
        'path': 'logo.png',
        'type': 'image',
        'mime': 'image/png',
        'size': 2048,
        'content_base64': 'iVBORw0KG',
        'truncated': false,
      });
      expect(c.type, 'image');
      expect(c.content, isNull);
      expect(c.contentBase64, 'iVBORw0KG');
    });

    test('二进制(无 content 字段)', () {
      final c = FileContent.fromJson({
        'path': 'archive.zip',
        'type': 'binary',
        'mime': 'application/octet-stream',
        'size': 9999,
      });
      expect(c.type, 'binary');
      expect(c.content, isNull);
      expect(c.contentBase64, isNull);
    });

    test('isText / isImage / isBinary getters', () {
      expect(FileContent.fromJson({'path': 'a', 'type': 'text', 'mime': '', 'size': 0}).isText, isTrue);
      expect(FileContent.fromJson({'path': 'a', 'type': 'image', 'mime': '', 'size': 0}).isImage, isTrue);
      expect(FileContent.fromJson({'path': 'a', 'type': 'binary', 'mime': '', 'size': 0}).isBinary, isTrue);
    });
  });
}
