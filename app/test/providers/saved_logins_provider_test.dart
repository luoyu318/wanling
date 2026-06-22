import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/models/saved_login.dart';
import 'package:app/providers/saved_logins_provider.dart';
import 'package:app/utils/secure_storage.dart';

void main() {
  late SharedPreferences prefs;
  late SecureStorage storage;
  late SavedLoginsNotifier notifier;
  String? lastSetBaseUrl;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    storage = SecureStorage(deviceId: 'test-device');
    lastSetBaseUrl = null;
    notifier = SavedLoginsNotifier(
      prefs: prefs,
      storage: storage,
      onBaseUrlChange: (url) => lastSetBaseUrl = url,
    );
  });

  group('load', () {
    test('空数据加载后 logins 为空 + selectedIndex 为 -1', () async {
      await notifier.load();
      expect(notifier.state.logins, isEmpty);
      expect(notifier.state.selectedIndex, -1);
    });

    test('加载已存数据', () async {
      await notifier.add('http://x', 'u', 'p');
      notifier.select(0);
      final notifier2 = SavedLoginsNotifier(
        prefs: prefs,
        storage: storage,
        onBaseUrlChange: (_) {},
      );
      await notifier2.load();
      expect(notifier2.state.logins.length, 1);
      expect(notifier2.state.logins[0].server, 'http://x');
      expect(notifier2.state.selectedIndex, 0);
    });

    test('解密失败清空数据(模拟密文损坏)', () async {
      await notifier.add('http://x', 'u', 'p');
      // 写入坏密文
      await prefs.setString('saved_logins', '!!!corrupted!!!');
      final notifier2 = SavedLoginsNotifier(
        prefs: prefs,
        storage: storage,
        onBaseUrlChange: (_) {},
      );
      await notifier2.load();
      expect(notifier2.state.logins, isEmpty);
      expect(notifier2.state.selectedIndex, -1);
      // 坏数据应被清除
      expect(prefs.getString('saved_logins'), isNull);
    });
  });

  group('add / saveOrAdd', () {
    test('add 新组合', () async {
      await notifier.add('http://x', 'u', 'p');
      expect(notifier.state.logins.length, 1);
    });

    test('add 重复组合更新密码', () async {
      await notifier.add('http://x', 'u', 'p1');
      await notifier.add('http://x', 'u', 'p2');
      expect(notifier.state.logins.length, 1);
      expect(notifier.state.logins[0].password, 'p2');
    });

    test('saveOrAdd 新组合并选中', () async {
      await notifier.saveOrAdd('http://x', 'u', 'p');
      expect(notifier.state.logins.length, 1);
      expect(notifier.state.selectedIndex, 0);
    });

    test('saveOrAdd 已存组合更新密码并选中', () async {
      await notifier.add('http://x', 'u', 'p1');
      await notifier.saveOrAdd('http://x', 'u', 'p2');
      expect(notifier.state.logins.length, 1);
      expect(notifier.state.logins[0].password, 'p2');
      expect(notifier.state.selectedIndex, 0);
    });
  });

  group('edit', () {
    test('edit 修改指定索引', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.edit(0, server: 'http://y', username: 'u2', password: 'p2');
      expect(notifier.state.logins[0].server, 'http://y');
      expect(notifier.state.logins[0].username, 'u2');
      expect(notifier.state.logins[0].password, 'p2');
    });

    test('edit 改成跟其他卡片撞 → 抛异常', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      expect(
        () => notifier.edit(0, server: 'http://y', username: 'u2'),
        throwsA(anything),
      );
    });

    test('edit 自身同 server+username 不算撞(只改密码)', () async {
      await notifier.add('http://x', 'u', 'p1');
      await notifier.edit(0, password: 'p2');
      expect(notifier.state.logins[0].password, 'p2');
    });
  });

  group('remove', () {
    test('remove 删除指定索引', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      await notifier.remove(0);
      expect(notifier.state.logins.length, 1);
      expect(notifier.state.logins[0].server, 'http://y');
    });

    test('remove 删的是选中项 → selectedIndex 回退 -1', () async {
      await notifier.add('http://x', 'u', 'p');
      notifier.select(0);
      expect(notifier.state.selectedIndex, 0);
      await notifier.remove(0);
      expect(notifier.state.selectedIndex, -1);
    });

    test('remove 删非选中项且在选中项之前 → selectedIndex 顺移', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      notifier.select(1);
      await notifier.remove(0);
      expect(notifier.state.selectedIndex, 0);
    });
  });

  group('select', () {
    test('select 设置 selectedIndex', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      notifier.select(1);
      expect(notifier.state.selectedIndex, 1);
    });

    test('select 触发 onBaseUrlChange 回调', () async {
      await notifier.add('http://x', 'u', 'p');
      notifier.select(0);
      expect(lastSetBaseUrl, 'http://x');
    });
  });

  group('持久化', () {
    test('add 后 prefs 有 saved_logins 密文', () async {
      await notifier.add('http://x', 'u', 'p');
      final saved = prefs.getString('saved_logins');
      expect(saved, isNotNull);
      expect(saved, isNot(contains('http://x'))); // 是密文不是明文
    });

    test('select 后 prefs 有 last_login_index', () async {
      await notifier.add('http://x', 'u', 'p');
      notifier.select(0);
      expect(prefs.getInt('last_login_index'), 0);
    });
  });
}
