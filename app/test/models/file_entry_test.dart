import 'package:wanling_core/models/file_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FileEntry.fromJson', () {
    test('目录条目', () {
      final e = FileEntry.fromJson({
        'name': 'src',
        'type': 'dir',
        'size': 0,
      });
      expect(e.name, 'src');
      expect(e.type, 'dir');
      expect(e.size, 0);
      expect(e.binary, isFalse);
    });

    test('文本文件条目(binary 缺省 → false)', () {
      final e = FileEntry.fromJson({
        'name': 'README.md',
        'type': 'file',
        'size': 1024,
      });
      expect(e.name, 'README.md');
      expect(e.type, 'file');
      expect(e.size, 1024);
      expect(e.binary, isFalse);
    });

    test('二进制条目(binary=true)', () {
      final e = FileEntry.fromJson({
        'name': 'archive.zip',
        'type': 'file',
        'size': 9999,
        'binary': true,
      });
      expect(e.binary, isTrue);
    });

    test('isDir getter', () {
      expect(FileEntry.fromJson({'name': 'a', 'type': 'dir', 'size': 0}).isDir, isTrue);
      expect(FileEntry.fromJson({'name': 'b', 'type': 'file', 'size': 1}).isDir, isFalse);
    });

    test('== / hashCode 按 name+type 判等', () {
      final a = FileEntry.fromJson({'name': 'x', 'type': 'file', 'size': 1});
      final b = FileEntry.fromJson({'name': 'x', 'type': 'file', 'size': 999});
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });
  });
}
