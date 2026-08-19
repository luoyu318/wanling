import 'dart:convert';
import 'dart:typed_data';

import 'package:wanling_core/services/local_message_key.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    // mock flutter_secure_storage (TokenVault 底层) 避免 device plugin 报错
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  group('LocalMessageKey', () {
    test('首次生成 32 字节随机密钥', () async {
      final k1 = await LocalMessageKey.getOrCreate(uid: 'user1');
      expect(k1.length, 32);
    });

    test('同 uid 稳定(round-trip 持久化)', () async {
      final k1 = await LocalMessageKey.getOrCreate(uid: 'user1');
      final k2 = await LocalMessageKey.getOrCreate(uid: 'user1');
      expect(k1, equals(k2));
    });

    test('密文损坏视同首次重新生成', () async {
      // 先生成
      final k1 = await LocalMessageKey.getOrCreate(uid: 'user1');
      // 故意写坏密文（直接通过 TokenVault 写入损坏值）
      const storage = FlutterSecureStorage();
      await storage.write(key: 'db_key_user1', value: '!!!not_base64!!!');
      // 重新 getOrCreate 应该返回新密钥(不抛异常)
      final k2 = await LocalMessageKey.getOrCreate(uid: 'user1');
      expect(k2.length, 32);
      expect(k1, isNot(equals(k2))); // 视同首次,新密钥
    });

    test('不同 uid 不同密钥(多账号隔离)', () async {
      final kA = await LocalMessageKey.getOrCreate(uid: 'userA');
      final kB = await LocalMessageKey.getOrCreate(uid: 'userB');
      expect(kA, isNot(equals(kB)));
    });

    test('clear 删除密钥后再生成是新的', () async {
      final k1 = await LocalMessageKey.getOrCreate(uid: 'user1');
      await LocalMessageKey.clear(uid: 'user1');
      final k2 = await LocalMessageKey.getOrCreate(uid: 'user1');
      expect(k1, isNot(equals(k2)));
    });

    test('dbFileName 同 uid 稳定 + 不同 uid 不同', () {
      final n1 = LocalMessageKey.dbFileName(uid: 'user1');
      final n2 = LocalMessageKey.dbFileName(uid: 'user1');
      expect(n1, equals(n2));
      expect(n1.startsWith('messages_'), isTrue);
      expect(n1.endsWith('.sqlite'), isTrue);

      final n3 = LocalMessageKey.dbFileName(uid: 'user2');
      expect(n1, isNot(equals(n3)));
    });

    // ---- 迁移:v1.2.0/v1.3.0 旧密钥从 SharedPreferences 搬到 TokenVault ----

    test('迁移:TokenVault 空时从旧 SharedPreferences 读取并搬运', () async {
      // 模拟 v1.3.0 老用户:旧密钥在 SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      const uid = 'legacy_user';
      final legacyBytes = List.generate(32, (i) => i);
      final legacyB64 = base64.encode(legacyBytes);
      await prefs.setString('local_db_key_v1:$uid', legacyB64);

      // getOrCreate 应读到旧密钥并迁移
      final key = await LocalMessageKey.getOrCreate(uid: uid);

      // 1) 返回的密钥必须等于旧密钥(不能重新生成)
      expect(key, equals(Uint8List.fromList(legacyBytes)));

      // 2) 旧 SharedPreferences 条目已删除(避免残留明文)
      expect(prefs.getString('local_db_key_v1:$uid'), isNull);

      // 3) 已写入 TokenVault(后续读直接命中新位置)
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'db_key_$uid'), equals(legacyB64));
    });

    test('迁移:TokenVault 已有值时不读旧 prefs(避免覆盖新密钥)', () async {
      const uid = 'user_with_both';
      // 新密钥已存在
      final newKey = await LocalMessageKey.getOrCreate(uid: uid);

      // 旧 prefs 也残存(用户先升级,后某种方式又写回旧值)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('local_db_key_v1:$uid', 'AAAAAAAAAAAAAAAA');

      // 应继续用 TokenVault 中的新密钥,不被旧值污染
      final again = await LocalMessageKey.getOrCreate(uid: uid);
      expect(again, equals(newKey));
      // 旧 prefs 条目残留(迁移路径只在 TokenVault 未命中时触发)
      // 这里仅验证不污染,不强求清理
    });
  });
}

