import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_storage.dart';

/// SQLCipher 密钥管理。
///
/// 设计:
/// - 首次为 uid 生成 32 字节随机密钥
/// - 密钥经 TokenVault (flutter_secure_storage / Android Keystore) 加密存储
/// - 后续读取从 TokenVault 解密获取
///
/// 不依赖设备属性(ANDROID_ID/Build.ID),原因:
/// - device_info_plus 已移除 ANDROID_ID 字段
/// - Build.ID 是系统镜像标签,OTA 升级会变,不适合做密钥派生
/// - Android Keystore 提供硬件级密钥保护,优于应用沙箱的文件级隔离
///
/// 迁移兼容:v1.2.0/v1.3.0 把密钥明文存 SharedPreferences(key 前缀
/// [_legacyPrefix])。升级到 TokenVault 版本时,[getOrCreate] 自动读取旧位置,
/// 搬运到 TokenVault 后删除旧条目,避免老用户本地消息库因密钥"丢失"被重建。
class LocalMessageKey {
  /// v1.2.0/v1.3.0 旧 SharedPreferences key 前缀(保留作迁移源)。
  static const _legacyPrefix = 'local_db_key_v1';

  static Future<Uint8List> getOrCreate({required String uid}) async {
    var cipherText = await TokenVault.getDbKey(uid);

    // 迁移:TokenVault 未命中时尝试从旧 SharedPreferences 读取并搬运。
    // 搬运成功后立即删除旧条目,避免重复迁移 / 残留明文。
    if (cipherText == null) {
      final prefs = await SharedPreferences.getInstance();
      final legacyKey = '$_legacyPrefix:$uid';
      final legacy = prefs.getString(legacyKey);
      if (legacy != null) {
        await TokenVault.saveDbKey(uid, legacy);
        await prefs.remove(legacyKey);
        cipherText = legacy;
      }
    }

    if (cipherText != null) {
      try {
        return Uint8List.fromList(base64.decode(cipherText));
      } catch (_) {
        // 密文损坏,视同首次
      }
    }

    // 生成新密钥
    final random = Random.secure();
    final bytes =
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
    await TokenVault.saveDbKey(uid, base64.encode(bytes));
    return bytes;
  }

  static Future<void> clear({required String uid}) async {
    await TokenVault.deleteDbKey(uid);
  }

  /// 计算 DB 文件名:`messages_<sha256(uid)[:16]>.sqlite`
  ///
  /// 注意:不再混入 deviceId。同账号 + 同设备 = 同文件名。
  /// 跨设备不会共享文件(应用沙箱本身隔离)。
  static String dbFileName({required String uid}) {
    final hash = sha256.convert(utf8.encode(uid)).toString();
    return 'messages_${hash.substring(0, 16)}.sqlite';
  }
}
