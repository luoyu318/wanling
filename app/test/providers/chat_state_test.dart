import 'package:app/providers/chat_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatState.shouldShowUnreadBadge', () {
    test('unreadCount > 0 → true', () {
      final s = ChatState(unreadCount: 1);
      expect(s.shouldShowUnreadBadge, isTrue);
    });

    test('unreadCount == 0 → false', () {
      final s = ChatState(unreadCount: 0);
      expect(s.shouldShowUnreadBadge, isFalse);
    });
  });

  group('ChatState.copyWith', () {
    test('clearFirstUnread: true 强制把 firstUnreadMessageId 置 null', () {
      final s = ChatState(firstUnreadMessageId: 'msg-1');
      final next = s.copyWith(clearFirstUnread: true);
      expect(next.firstUnreadMessageId, isNull);
    });

    test('clearFirstUnread: false（默认）保留 firstUnreadMessageId', () {
      final s = ChatState(firstUnreadMessageId: 'msg-1');
      final next = s.copyWith(messages: []);
      expect(next.firstUnreadMessageId, 'msg-1');
    });
  });
}
