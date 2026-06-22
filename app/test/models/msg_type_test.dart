import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/msg_type.dart';

void main() {
  group('MsgTypeX', () {
    test('fromString 把已知字符串映射到 enum', () {
      expect(MsgTypeX.fromString('text'), MsgType.text);
      expect(MsgTypeX.fromString('markdown'), MsgType.markdown);
      expect(MsgTypeX.fromString('image'), MsgType.image);
      expect(MsgTypeX.fromString('file'), MsgType.file);
      expect(MsgTypeX.fromString('mixed'), MsgType.mixed);
    });

    test('fromString 兼容 null / 未知值（fallback unknown）', () {
      expect(MsgTypeX.fromString(null), MsgType.unknown);
      expect(MsgTypeX.fromString(''), MsgType.unknown);
      expect(MsgTypeX.fromString('weird'), MsgType.unknown);
    });

    test('value 与后端契约字符串一致', () {
      expect(MsgType.text.value, 'text');
      expect(MsgType.image.value, 'image');
    });
  });
}
