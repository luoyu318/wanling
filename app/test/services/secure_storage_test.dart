import 'dart:convert';

import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/services/secure_storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    // flutter_secure_storage 在 flutter test 环境无原生通道,
    // setMockInitialValues 注入内存实现,所有 read/write/delete 走内存 Map。
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('TokenVault', () {
    test('saveTokens + getAccessToken/getRefreshToken 往返一致', () async {
      await TokenVault.saveTokens('access-1', 'refresh-1');
      expect(await TokenVault.getAccessToken(), 'access-1');
      expect(await TokenVault.getRefreshToken(), 'refresh-1');
    });

    test('saveAccessToken 仅更新 access,不影响 refresh', () async {
      await TokenVault.saveTokens('access-1', 'refresh-1');
      await TokenVault.saveAccessToken('access-2');
      expect(await TokenVault.getAccessToken(), 'access-2');
      expect(await TokenVault.getRefreshToken(), 'refresh-1');
    });

    test('未存储时 get* 返回 null', () async {
      expect(await TokenVault.getAccessToken(), isNull);
      expect(await TokenVault.getRefreshToken(), isNull);
      expect(await TokenVault.getUserId(), isNull);
      expect(await TokenVault.getUser(), isNull);
    });

    test('saveUserId + getUserId 往返一致', () async {
      await TokenVault.saveUserId('user-42');
      expect(await TokenVault.getUserId(), 'user-42');
    });

    test('saveUser + getUser 往返一致(完整字段)', () async {
      final user = User(
        id: 'u1',
        username: 'alice',
        nickname: 'Alice',
        bio: 'hello',
        avatarUrl: 'http://example.com/a.png',
        createdAt: DateTime.utc(2026, 7, 12),
      );
      await TokenVault.saveUser(user);
      final restored = await TokenVault.getUser();
      expect(restored, isNotNull);
      expect(restored!.id, 'u1');
      expect(restored.username, 'alice');
      expect(restored.nickname, 'Alice');
      expect(restored.bio, 'hello');
      expect(restored.avatarUrl, 'http://example.com/a.png');
    });

    test('getUser 损坏 JSON 返回 null(不抛异常)', () async {
      // 直接写一个非 JSON 字符串模拟损坏
      const storage = FlutterSecureStorage();
      await storage.write(key: 'cached_user', value: '<not json>');
      expect(await TokenVault.getUser(), isNull);
    });

    test('saveUser JSON 包含正确字段(toJson)', () async {
      final user = User(
        id: 'u1',
        username: 'alice',
        nickname: null,
        bio: null,
        avatarUrl: null,
        createdAt: DateTime.utc(2026, 7, 12),
      );
      await TokenVault.saveUser(user);

      const storage = FlutterSecureStorage();
      final raw = await storage.read(key: 'cached_user');
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      expect(decoded['id'], 'u1');
      expect(decoded['username'], 'alice');
      expect(decoded['nickname'], isNull);
    });

    test('clearAll 清空所有 token + user', () async {
      await TokenVault.saveTokens('a', 'r');
      await TokenVault.saveUserId('u1');
      await TokenVault.saveUser(User(
        id: 'u1',
        username: 'alice',
        createdAt: DateTime.utc(2026, 7, 12),
      ));
      await TokenVault.clearAll();
      expect(await TokenVault.getAccessToken(), isNull);
      expect(await TokenVault.getRefreshToken(), isNull);
      expect(await TokenVault.getUserId(), isNull);
      expect(await TokenVault.getUser(), isNull);
    });

    test('clearAuth 清认证态 + DB 密钥,保留 aes_key', () async {
      // aes_key 是 saved_logins 的跨账号加密密钥,登出/401 时一并清掉
      // 会让下次启动密文无法解密被静默清空(配置丢失 bug 的根因)。
      await TokenVault.saveTokens('a', 'r');
      await TokenVault.saveUserId('u1');
      await TokenVault.saveUser(User(
        id: 'u1',
        username: 'alice',
        createdAt: DateTime.utc(2026, 7, 12),
      ));
      await TokenVault.saveDbKey('u1', 'dbkey-base64');
      await TokenVault.saveAesKey('aes-base64');

      await TokenVault.clearAuth();

      expect(await TokenVault.getAccessToken(), isNull);
      expect(await TokenVault.getRefreshToken(), isNull);
      expect(await TokenVault.getUserId(), isNull);
      expect(await TokenVault.getUser(), isNull);
      expect(await TokenVault.getDbKey('u1'), isNull);
      expect(await TokenVault.getAesKey(), 'aes-base64');
    });

    test('saveTokens 覆盖旧值(rotation 场景)', () async {
      await TokenVault.saveTokens('access-old', 'refresh-old');
      await TokenVault.saveTokens('access-new', 'refresh-new');
      expect(await TokenVault.getAccessToken(), 'access-new');
      expect(await TokenVault.getRefreshToken(), 'refresh-new');
    });
  });
}
