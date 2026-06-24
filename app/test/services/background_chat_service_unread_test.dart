import 'package:app/services/background_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UnreadCounter', () {
    test('初始值为 0', () {
      final counter = UnreadCounter();
      expect(counter.get('conv-1'), 0);
    });

    test('收消息累加', () {
      final counter = UnreadCounter();
      counter.increment('conv-1');
      counter.increment('conv-1');
      expect(counter.get('conv-1'), 2);
    });

    test('进入会话清零,清零后重新累加', () {
      final counter = UnreadCounter();
      counter.increment('conv-1');
      counter.increment('conv-1');
      expect(counter.get('conv-1'), 2);

      counter.clear('conv-1');
      expect(counter.get('conv-1'), 0);

      counter.increment('conv-1');
      expect(counter.get('conv-1'), 1);
    });

    test('不同会话独立计数', () {
      final counter = UnreadCounter();
      counter.increment('conv-1');
      counter.increment('conv-1');
      counter.increment('conv-2');
      expect(counter.get('conv-1'), 2);
      expect(counter.get('conv-2'), 1);
      // 清 conv-1 不影响 conv-2
      counter.clear('conv-1');
      expect(counter.get('conv-1'), 0);
      expect(counter.get('conv-2'), 1);
    });
  });
}
