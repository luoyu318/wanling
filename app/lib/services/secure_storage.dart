import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/user.dart';

/// JWT token + 用户资料的安全存储封装(Android Keystore 加密)。
///
/// 取代旧版明文 SharedPreferences 存储策略:
/// - refresh_token:仅存此处(高价值 30d token,泄露窗口长)
/// - access_token:此处 + SharedPreferences 双写(双写原因:bg-service isolate
///   内平台通道受限,需从 SharedPreferences 读 token 做 WS auto-restore;
///   access TTL 仅 2h,即便明文暴露窗口也短)
///
/// 测试环境用 `FlutterSecureStorage.setMockInitialValues({})` 注入内存实现。
///
/// 命名:与 utils/secure_storage.dart 的 SecureStorage(AES-GCM 加密 helper)
/// 区分,本类专注 token + 用户凭证的 Keystore 存储。
class TokenVault {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _keyAccessToken = 'access_token';
  static const _keyRefreshToken = 'refresh_token';
  static const _keyUserId = 'user_id';
  static const _keyCachedUser = 'cached_user';
  static const _keyDbKeyPrefix = 'db_key_';
  static const _keyAesKey = 'aes_key';

  static Future<void> saveTokens(String access, String refresh) async {
    await _storage.write(key: _keyAccessToken, value: access);
    await _storage.write(key: _keyRefreshToken, value: refresh);
  }

  static Future<void> saveAccessToken(String token) async {
    await _storage.write(key: _keyAccessToken, value: token);
  }

  static Future<String?> getAccessToken() async {
    return _storage.read(key: _keyAccessToken);
  }

  static Future<String?> getRefreshToken() async {
    return _storage.read(key: _keyRefreshToken);
  }

  static Future<void> saveUserId(String userId) async {
    await _storage.write(key: _keyUserId, value: userId);
  }

  static Future<String?> getUserId() async {
    return _storage.read(key: _keyUserId);
  }

  static Future<void> saveUser(User user) async {
    await _storage.write(key: _keyCachedUser, value: jsonEncode(user.toJson()));
  }

  static Future<User?> getUser() async {
    final json = await _storage.read(key: _keyCachedUser);
    if (json == null) return null;
    try {
      return User.fromJson(jsonDecode(json) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearAll() async {
    await _storage.deleteAll();
  }

  /// 清除认证态 + per-user DB 密钥,**保留 saved_logins 的 aes_key**。
  ///
  /// 登出/401 用此方法替代 clearAll:aes_key 是跨账号共享的本地配置加密密钥,
  /// 一并清掉会让 SharedPreferences 里的 saved_logins 密文无法解密,
  /// 下次启动 load() 解密失败导致配置被静默清空。
  static Future<void> clearAuth() async {
    final all = await _storage.readAll();
    // 复制 keys 再删:readAll 返回的是底层 live view,
    // 迭代中 delete 会触发 concurrent modification。
    for (final key in all.keys.toList()) {
      if (key == _keyAesKey) continue;
      await _storage.delete(key: key);
    }
  }

  // --- SQLCipher DB 密钥 ---

  static Future<void> saveDbKey(String uid, String base64Key) async {
    await _storage.write(key: '$_keyDbKeyPrefix$uid', value: base64Key);
  }

  static Future<String?> getDbKey(String uid) async {
    return _storage.read(key: '$_keyDbKeyPrefix$uid');
  }

  static Future<void> deleteDbKey(String uid) async {
    await _storage.delete(key: '$_keyDbKeyPrefix$uid');
  }

  // --- AES 加密密钥（saved_logins 用） ---

  static Future<void> saveAesKey(String base64Key) async {
    await _storage.write(key: _keyAesKey, value: base64Key);
  }

  static Future<String?> getAesKey() async {
    return _storage.read(key: _keyAesKey);
  }

  static Future<void> deleteAesKey() async {
    await _storage.delete(key: _keyAesKey);
  }
}
