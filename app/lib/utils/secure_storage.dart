import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:encrypt/encrypt.dart' as enc;

/// AES-256-GCM 加解密 + 设备信息派生密钥。
///
/// 密钥派生:SHA256(`com.wanling.app` | ANDROID_ID | `<固定盐>`) 前 32 字节。
/// 换设备/重装失效(ANDROID_ID 变),符合本地绑定语义。
///
/// 生产环境用真实 ANDROID_ID;测试通过构造函数注入固定 deviceId。
class SecureStorage {
  static const _packageName = 'com.wanling.app';
  static const _salt = 'wanling-v1-fixed-salt';

  /// 注入的 deviceId(测试用)。生产环境为 null,内部异步从 device_info_plus 拉取。
  final String? _deviceId;

  /// 默认工厂:生产环境用。测试通过 SecureStorage(deviceId: '...') 注入。
  SecureStorage({String? deviceId}) : _deviceId = deviceId;

  /// 加密明文 → 返回 `base64(iv):base64(ciphertext)`。
  Future<String> encrypt(String plaintext) async {
    final key = await _deriveKey();
    final iv = enc.IV.fromSecureRandom(12); // GCM 推荐 12 字节 IV
    final encrypter = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.gcm),
    );
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    return '${iv.base64}:${encrypted.base64}';
  }

  /// 解密 `base64(iv):base64(ciphertext)` → 明文。
  /// 坏密文/错密钥抛异常。
  Future<String> decrypt(String ciphertext) async {
    final parts = ciphertext.split(':');
    if (parts.length != 2) {
      throw const FormatException('密文格式错误:缺少 IV 分隔符');
    }
    final key = await _deriveKey();
    final iv = enc.IV.fromBase64(parts[0]);
    final encrypted = enc.Encrypted.fromBase64(parts[1]);
    final encrypter = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.gcm),
    );
    return encrypter.decrypt(encrypted, iv: iv);
  }

  /// 派生 AES-256 密钥(32 字节)。
  Future<enc.Key> _deriveKey() async {
    final deviceId = _deviceId ?? await _readAndroidId();
    final material = utf8.encode('$_packageName|$deviceId|$_salt');
    final digest = sha256.convert(material);
    // 前 32 字节作为 AES-256 密钥
    return enc.Key(Uint8List.fromList(digest.bytes.sublist(0, 32)));
  }

  /// 从 device_info_plus 读 ANDROID_ID。
  /// 失败时降级返回空字符串(用固定盐 + 包名派生,安全性降低但不崩)。
  Future<String> _readAndroidId() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      // androidId 在 AndroidDeviceInfo 上是直接字段;某些版本可能为空。
      return info.id;
    } catch (_) {
      return '';
    }
  }
}
