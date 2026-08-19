import 'package:wanling_core/models/user.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('User JSON 往返', () {
    test('toJson → fromJson 应等于原对象', () {
      final original = User(
        id: 'u1',
        username: 'alice',
        nickname: 'Alice',
        bio: 'hello',
        avatarUrl: 'http://example.com/a.png',
        createdAt: DateTime.utc(2026, 7, 5, 10, 0, 0),
      );
      final encoded = original.toJson();
      final decoded = User.fromJson(encoded);
      expect(decoded.id, original.id);
      expect(decoded.username, original.username);
      expect(decoded.nickname, original.nickname);
      expect(decoded.bio, original.bio);
      expect(decoded.avatarUrl, original.avatarUrl);
      expect(decoded.createdAt.toIso8601String(), original.createdAt.toIso8601String());
    });

    test('toJson nullable 字段为 null 时正常编码', () {
      final original = User(
        id: 'u1',
        username: 'bob',
        nickname: null,
        bio: null,
        avatarUrl: null,
        createdAt: DateTime.utc(2026, 7, 5),
      );
      final encoded = original.toJson();
      expect(encoded['nickname'], isNull);
      expect(encoded['bio'], isNull);
      expect(encoded['avatar_url'], isNull);
    });
  });
}
