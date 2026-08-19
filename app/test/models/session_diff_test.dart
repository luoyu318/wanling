import 'package:wanling_core/models/session_diff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionDiffFile.fromJson', () {
    test('完整字段解析', () {
      final f = SessionDiffFile.fromJson({
        'file': 'main.go',
        'patch': '@@ -1 +1 @@',
        'additions': 5,
        'deletions': 2,
        'status': 'modified',
      });
      expect(f.file, 'main.go');
      expect(f.patch, '@@ -1 +1 @@');
      expect(f.additions, 5);
      expect(f.deletions, 2);
      expect(f.status, 'modified');
    });

    test('status 缺失时为 null', () {
      final f = SessionDiffFile.fromJson({
        'file': 'a.go',
        'patch': '',
        'additions': 0,
        'deletions': 0,
      });
      expect(f.status, isNull);
    });

    test('deleted 文件 patch 空字符串', () {
      final f = SessionDiffFile.fromJson({
        'file': 'old.go',
        'patch': '',
        'additions': 0,
        'deletions': 10,
        'status': 'deleted',
      });
      expect(f.patch, '');
      expect(f.status, 'deleted');
    });
  });
}
