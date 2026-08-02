import 'package:flutter_test/flutter_test.dart';
import 'package:app/utils/secure_storage.dart';

void main() {
  group('SecureStorage', () {
    test('encrypt + decrypt 往返一致', () async {
      final storage = SecureStorage(deviceId: 'test-device-id');
      const plaintext = 'hello world {"server":"http://x"}';
      final ciphertext = await storage.encrypt(plaintext);
      final decrypted = await storage.decrypt(ciphertext);
      expect(decrypted, plaintext);
    });

    test('不同明文产生不同密文', () async {
      final storage = SecureStorage(deviceId: 'test-device-id');
      final c1 = await storage.encrypt('plaintext-1');
      final c2 = await storage.encrypt('plaintext-2');
      expect(c1, isNot(c2));
    });

    test('相同明文不同次加密产生不同密文(随机 IV)', () async {
      final storage = SecureStorage(deviceId: 'test-device-id');
      final c1 = await storage.encrypt('same-plaintext');
      final c2 = await storage.encrypt('same-plaintext');
      expect(c1, isNot(c2));
    });

    test('相同明文不同次加密解密都正确', () async {
      final storage = SecureStorage(deviceId: 'test-device-id');
      final c1 = await storage.encrypt('same');
      final c2 = await storage.encrypt('same');
      expect(await storage.decrypt(c1), 'same');
      expect(await storage.decrypt(c2), 'same');
    });

    test('不同 deviceId 派生不同密钥(跨设备密文不可解)', () async {
      final storage1 = SecureStorage(deviceId: 'device-A');
      final storage2 = SecureStorage(deviceId: 'device-B');
      const plaintext = 'secret';
      final ciphertext = await storage1.encrypt(plaintext);
      expect(
        () async => storage2.decrypt(ciphertext),
        throwsA(anything),
      );
    });

    test('坏密文(缺 IV 分隔符)抛异常', () async {
      final storage = SecureStorage(deviceId: 'test-device-id');
      expect(
        () async => storage.decrypt('dGVzdA=='),
        throwsA(anything),
      );
    });

    test('坏密文(非 base64)抛异常', () async {
      final storage = SecureStorage(deviceId: 'test-device-id');
      expect(
        () async => storage.decrypt('!!!not-valid!!!:xxx'),
        throwsA(anything),
      );
    });

    test('空字符串加密解密', () async {
      final storage = SecureStorage(deviceId: 'test-device-id');
      final ciphertext = await storage.encrypt('');
      expect(await storage.decrypt(ciphertext), '');
    });
  });
}
