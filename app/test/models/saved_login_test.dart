import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/saved_login.dart';
import 'package:app/models/account_mark.dart';

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

    test('label + mark 序列化往返', () {
      final a = SavedLogin(
        server: 'http://x',
        username: 'u',
        password: 'p',
        label: '公司服',
        mark: const AccountMark(colorIndex: 2, emoji: '🟢'),
      );
      final json = a.toJson();
      expect(json['label'], '公司服');
      expect(json['mark'], {'colorIndex': 2, 'emoji': '🟢'});
      final b = SavedLogin.fromJson(json);
      expect(b.label, '公司服');
      expect(b.mark?.colorIndex, 2);
      expect(b.mark?.emoji, '🟢');
    });

    test('fromJson 老数据(无 label/mark)返回 null', () {
      // 模拟老版本持久化格式
      final a = SavedLogin.fromJson({
        'server': 'http://x',
        'username': 'u',
        'password': 'p',
      });
      expect(a.label, isNull);
      expect(a.mark, isNull);
      expect(a.server, 'http://x');
    });

    test('toJson label/mark 为 null 时不带对应键', () {
      final a = SavedLogin(server: 'http://x', username: 'u', password: 'p');
      final json = a.toJson();
      expect(json.containsKey('label'), isFalse);
      expect(json.containsKey('mark'), isFalse);
    });

    test('copyWith 改 label/mark', () {
      final a = SavedLogin(server: 'http://x', username: 'u', password: 'p');
      final b = a.copyWith(
        label: '测试服',
        mark: const AccountMark(colorIndex: 1),
      );
      expect(b.label, '测试服');
      expect(b.mark?.colorIndex, 1);
      expect(b.server, 'http://x'); // 其他字段保持
    });

    test('== 不受 label/mark 影响(同 server+username 视为相等)', () {
      final a = SavedLogin(
        server: 'http://x', username: 'u', password: 'p1',
        label: 'A', mark: const AccountMark(colorIndex: 0),
      );
      final b = SavedLogin(
        server: 'http://x', username: 'u', password: 'p2',
        label: 'B', mark: const AccountMark(colorIndex: 5),
      );
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });
  });
}
