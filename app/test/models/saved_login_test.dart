import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/saved_login.dart';

void main() {
  group('SavedLogin', () {
    test('matches 同 server+username 返回 true', () {
      final a = SavedLogin(server: 'http://x', username: 'u', password: 'p');
      expect(a.matches('http://x', 'u'), isTrue);
    });

    test('matches 不同 server 返回 false', () {
      final a = SavedLogin(server: 'http://x', username: 'u', password: 'p');
      expect(a.matches('http://y', 'u'), isFalse);
    });

    test('matches 不同 username 返回 false', () {
      final a = SavedLogin(server: 'http://x', username: 'u', password: 'p');
      expect(a.matches('http://x', 'v'), isFalse);
    });

    test('toJson 序列化包含三字段', () {
      final a = SavedLogin(server: 'http://x', username: 'u', password: 'p');
      expect(a.toJson(), {
        'server': 'http://x',
        'username': 'u',
        'password': 'p',
      });
    });

    test('fromJson 反序列化正确', () {
      final a = SavedLogin.fromJson({
        'server': 'http://x',
        'username': 'u',
        'password': 'p',
      });
      expect(a.server, 'http://x');
      expect(a.username, 'u');
      expect(a.password, 'p');
    });

    test('copyWith 只改指定字段', () {
      final a = SavedLogin(server: 'http://x', username: 'u', password: 'p');
      final b = a.copyWith(password: 'new');
      expect(b.server, 'http://x');
      expect(b.username, 'u');
      expect(b.password, 'new');
    });

    test('相等性:同 server+username 视为相等', () {
      final a = SavedLogin(server: 'http://x', username: 'u', password: 'p1');
      final b = SavedLogin(server: 'http://x', username: 'u', password: 'p2');
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });
  });
}
