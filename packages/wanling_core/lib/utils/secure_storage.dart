import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

import 'package:wanling_core/services/secure_storage.dart';

/// AES-256-GCM 加解密 + TokenVault 密钥管理。
///
/// 密钥来源:
/// - 生产模式(默认):首次使用时生成 32 字节随机密钥,存入 TokenVault
///   (flutter_secure_storage / Android Keystore)。后续直接读取。
/// - 测试模式(注入 deviceId):用 SHA256(deviceId) 派生密钥,绕过 TokenVault。
///
/// 旧版用 ANDROID_ID 派生密钥,存在同设备可解密风险;
/// 现改为 Keystore 保护的随机密钥,安全性等同硬件级。
///
/// 密钥迁移:旧密文(ANDROID_ID 派生)无法用新密钥解密,
/// 调用方应捕获解密异常并视为"无保存数据"(降级处理)。
class SecureStorage {
  static const _packageName = 'com.wanling.app';

  /// 注入的 deviceId(测试用)。生产环境为 null,从 TokenVault 读取随机密钥。
  final String? _deviceId;

  /// 默认工厂:生产环境用。测试通过 SecureStorage(deviceId: '...') 注入。
  SecureStorage({String? deviceId}) : _deviceId = deviceId;

  /// 加密明文 → 返回 `base64(iv):base64(ciphertext)`。
  Future<String> encrypt(String plaintext) async {
    final key = await _getOrCreateKey();
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
    final key = await _getOrCreateKey();
    final iv = enc.IV.fromBase64(parts[0]);
    final encrypted = enc.Encrypted.fromBase64(parts[1]);
    final encrypter = enc.Encrypter(
      enc.AES(key, mode: enc.AESMode.gcm),
    );
    return encrypter.decrypt(encrypted, iv: iv);
  }

  /// 获取或生成 AES-256 密钥(32 字节)。
  /// 测试模式:SHA256(deviceId) 派生(确定性,不依赖 TokenVault)。
  /// 生产模式:从 TokenVault 读取随机密钥(不存在则生成并存储)。
  Future<enc.Key> _getOrCreateKey() async {
    if (_deviceId != null) {
      final material = utf8.encode('$_packageName|$_deviceId');
      final digest = sha256.convert(material);
      return enc.Key(Uint8List.fromList(digest.bytes.sublist(0, 32)));
    }

    final base64Key = await TokenVault.getAesKey();
    if (base64Key != null) {
      return enc.Key(Uint8List.fromList(base64.decode(base64Key)));
    }

    // 首次使用:生成随机密钥并存入 TokenVault
    final random = Random.secure();
    final bytes =
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    await TokenVault.saveAesKey(base64.encode(bytes));
    return enc.Key(Uint8List.fromList(bytes));
  }
}
