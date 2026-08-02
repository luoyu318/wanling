import 'package:app/models/friendship.dart';
import 'package:app/models/user_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FriendRequest JSON 往返', () {
    test('toJson → fromJson 应等于原对象', () {
      final original = FriendRequest(
        id: 'r1',
        status: FriendshipStatus.pending,
        createdAt: DateTime.utc(2026, 7, 5, 10, 0, 0),
        user: UserSummary(username: 'bob', nickname: 'Bob', avatarUrl: ''),
      );
      final encoded = original.toJson();
      final decoded = FriendRequest.fromJson(encoded);
      expect(decoded.id, original.id);
      expect(decoded.status, FriendshipStatus.pending);
      expect(decoded.user.username, 'bob');
    });
  });
}
