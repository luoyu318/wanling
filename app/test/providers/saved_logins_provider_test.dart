import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/models/account_mark.dart';
import 'package:app/models/saved_login.dart';
import 'package:app/providers/saved_logins_provider.dart';
import 'package:app/utils/secure_storage.dart';

void main() {
  late SharedPreferences prefs;
  late SecureStorage storage;
  late SavedLoginsNotifier notifier;
  String? lastSetBaseUrl;
  int logoutCallCount = 0;
  List<String> loginCalls = [];
  List<bool> switchingCalls = [];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    storage = SecureStorage(deviceId: 'test-device');
    lastSetBaseUrl = null;
    logoutCallCount = 0;
    loginCalls = [];
    switchingCalls = [];
    notifier = SavedLoginsNotifier(
      prefs: prefs,
      storage: storage,
      onBaseUrlChange: (url) => lastSetBaseUrl = url,
      onLogout: ({bool silent = false}) async => logoutCallCount++,
      onLogin: (u, p) async => loginCalls.add('$u:$p'),
      onSwitchingChange: (s) => switchingCalls.add(s),
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
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async {},
        onSwitchingChange: (_) {},
      );
      await notifier2.load();
      expect(notifier2.state.logins.length, 1);
      expect(notifier2.state.logins[0].server, 'http://x');
      expect(notifier2.state.selectedIndex, 0);
    });

    test('解密失败降级空状态 + 保留密文(防数据销毁)', () async {
      // 密文格式坏:解密必然失败,但密文本身可能未来有用(如多密钥回退),
      // 不应在解密失败时主动销毁——保留让下次保存自然覆盖更安全。
      await notifier.add('http://x', 'u', 'p');
      await prefs.setString('saved_logins', '!!!corrupted!!!');
      final notifier2 = SavedLoginsNotifier(
        prefs: prefs,
        storage: storage,
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async {},
        onSwitchingChange: (_) {},
      );
      await notifier2.load();
      expect(notifier2.state.logins, isEmpty);
      expect(notifier2.state.selectedIndex, -1);
      expect(prefs.getString('saved_logins'), isNotNull,
          reason: '解密失败时不应销毁密文:密钥可能仅临时不可用,'
              '主动 remove 会让"密钥临时不可用"演变为"永久丢数据"');
    });

    test('密钥丢失场景(密文完好但密钥变)→降级空状态 + 保留密文', () async {
      // 复现配置丢失 bug 场景:aes_key 被误删后,_getOrCreateKey 生成新 K',
      // 用 K' 解旧密文必然失败。旧实现此时 remove('saved_logins') 抹掉全部配置。
      final storageA = SecureStorage(deviceId: 'device-A');
      final notifierA = SavedLoginsNotifier(
        prefs: prefs,
        storage: storageA,
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async {},
        onSwitchingChange: (_) {},
      );
      await notifierA.add('http://x', 'u', 'p');

      // 换 deviceId 模拟密钥变化(等同于 aes_key 被清后重新生成)
      final storageB = SecureStorage(deviceId: 'device-B');
      final notifierB = SavedLoginsNotifier(
        prefs: prefs,
        storage: storageB,
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async {},
        onSwitchingChange: (_) {},
      );
      await notifierB.load();

      expect(notifierB.state.logins, isEmpty);
      expect(notifierB.state.selectedIndex, -1);
      expect(prefs.getString('saved_logins'), isNotNull,
          reason: '密文本身完好,只是密钥暂时对不上,必须保留以待未来恢复');
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

    test('add select:false 新增不改变当前选中', () async {
      await notifier.add('http://x', 'u1', 'p1');
      notifier.select(0);
      await notifier.add('http://y', 'u2', 'p2', select: false);
      expect(notifier.state.logins.length, 2);
      expect(notifier.state.selectedIndex, 0); // 仍选中原账号
    });

    test('add select:false 重复组合更新密码不改变当前选中', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      notifier.select(0);
      await notifier.add('http://y', 'u2', 'p3', select: false);
      expect(notifier.state.logins.length, 2);
      expect(notifier.state.logins[1].password, 'p3');
      expect(notifier.state.selectedIndex, 0);
    });

    test('saveOrAdd select:false 保持原选中', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      notifier.select(0);
      await notifier.saveOrAdd('http://z', 'u3', 'p3', select: false);
      expect(notifier.state.logins.length, 3);
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

  group('duplicate', () {
    test('克隆完整卡片插入列表末尾,username 加后缀避免唯一性冲突', () async {
      await notifier.add('http://x', 'u1', 'p1', label: '开发', mark: const AccountMark(colorIndex: 2));
      await notifier.duplicate(0);
      expect(notifier.state.logins.length, 2);
      final clone = notifier.state.logins[1];
      expect(clone.server, 'http://x');
      expect(clone.password, 'p1');
      expect(clone.label, '开发');
      expect(clone.mark?.colorIndex, 2);
      expect(clone.username, 'u1_copy');
    });

    test('username 冲突时后缀递增到不冲突', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://x', 'u1_copy', 'p2');
      await notifier.duplicate(0);
      expect(notifier.state.logins.length, 3);
      expect(notifier.state.logins[2].username, 'u1_copy_2');
    });

    test('duplicate 不改变当前选中', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      notifier.select(1);
      await notifier.duplicate(0);
      expect(notifier.state.selectedIndex, 1);
    });

    test('duplicate 越界抛 RangeError', () async {
      await notifier.add('http://x', 'u1', 'p1');
      expect(
        () => notifier.duplicate(5),
        throwsA(isA<RangeError>()),
      );
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

  group('switchTo', () {
    test('成功:依次触发 logout → onBaseUrlChange → login', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      notifier.select(0);
      // 切换前重置计数
      logoutCallCount = 0;
      loginCalls = [];
      lastSetBaseUrl = null;
      switchingCalls = [];

      await notifier.switchTo(1);

      expect(logoutCallCount, 1);
      expect(lastSetBaseUrl, 'http://y'); // select 触发 setBaseUrl
      expect(loginCalls, ['u2:p2']);
      expect(notifier.state.selectedIndex, 1);
      // isSwitching:silent logout 保留标志,无需重置。开始(true)→结束(false)
      expect(switchingCalls, [true, false]);
    });

    test('同索引 no-op(不触发任何回调)', () async {
      await notifier.add('http://x', 'u', 'p');
      notifier.select(0);
      logoutCallCount = 0;
      loginCalls = [];
      switchingCalls = [];

      await notifier.switchTo(0);

      expect(logoutCallCount, 0);
      expect(loginCalls, isEmpty);
      expect(switchingCalls, isEmpty); // no-op 不进入切换流程
    });

    test('login 失败:selectedIndex 回滚到切换前 + 抛异常', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      notifier.select(0);

      // 重建一个 login 会失败的 notifier
      final failingNotifier = SavedLoginsNotifier(
        prefs: prefs,
        storage: storage,
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async => throw Exception('login failed'),
        onSwitchingChange: (_) {},
      );
      await failingNotifier.load();
      failingNotifier.select(0);

      expect(
        () => failingNotifier.switchTo(1),
        throwsA(isA<Exception>()),
      );
      await Future.delayed(Duration.zero); // 让 microtask 跑完
      expect(failingNotifier.state.selectedIndex, 0); // 回滚
    });

    test('越界抛 RangeError', () async {
      await notifier.add('http://x', 'u', 'p');
      expect(
        () => notifier.switchTo(5),
        throwsA(isA<RangeError>()),
      );
    });

    test('负索引抛 RangeError', () async {
      await notifier.add('http://x', 'u', 'p');
      expect(
        () => notifier.switchTo(-1),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('loginWith', () {
    test('即使 index==selectedIndex 也触发 onLogin(不短路)', () async {
      // SelectAccountPage 登出态场景:selectedIndex 仍指向前次登录账号,
      // 用户点同索引卡片本意是"用保存密码重新登录"。
      // switchTo 在此处会 no-op,故 SelectAccountPage 改用 loginWith。
      await notifier.add('http://x', 'u1', 'p1');
      notifier.select(0); // 模拟前次登录选中态
      // 重置回调记录
      loginCalls = [];
      logoutCallCount = 0;

      await notifier.loginWith(0);

      expect(loginCalls, ['u1:p1'],
          reason: '已选中卡片也必须触发 login,不能因 index==selected 短路');
    });

    test('不触发 onLogout(登出态调用,无需重复登出)', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      notifier.select(0);
      logoutCallCount = 0;

      await notifier.loginWith(1);

      expect(logoutCallCount, 0,
          reason: 'loginWith 用于已登出态,不需要 silent logout 步骤');
    });

    test('同步 selectedIndex + onBaseUrlChange 到目标账号', () async {
      await notifier.add('http://x', 'u1', 'p1');
      await notifier.add('http://y', 'u2', 'p2');
      notifier.select(0);
      lastSetBaseUrl = null;

      await notifier.loginWith(1);

      expect(notifier.state.selectedIndex, 1);
      expect(lastSetBaseUrl, 'http://y');
    });

    test('越界抛 RangeError', () async {
      await notifier.add('http://x', 'u', 'p');
      expect(
        () => notifier.loginWith(5),
        throwsA(isA<RangeError>()),
      );
    });

    test('onLogin 失败抛异常(回滚由调用方 UI 处理)', () async {
      await notifier.add('http://x', 'u', 'p');
      final failingNotifier = SavedLoginsNotifier(
        prefs: prefs,
        storage: storage,
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async => throw Exception('login failed'),
        onSwitchingChange: (_) {},
      );
      await failingNotifier.load();

      expect(
        () => failingNotifier.loginWith(0),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('edit 带 label/mark', () {
    test('edit 设置 label 和 mark', () async {
      await notifier.add('http://x', 'u', 'p');
      await notifier.edit(
        0,
        label: '公司服',
        mark: const AccountMark(colorIndex: 2, emoji: '🟢'),
      );
      expect(notifier.state.logins[0].label, '公司服');
      expect(notifier.state.logins[0].mark?.colorIndex, 2);
      expect(notifier.state.logins[0].mark?.emoji, '🟢');
    });

    test('edit 传空 label 字符串 → 清空为 null', () async {
      await notifier.add('http://x', 'u', 'p', label: '旧名');
      await notifier.edit(0, label: '');
      expect(notifier.state.logins[0].label, isNull);
    });

    test('edit 不传 label → 保持原值', () async {
      await notifier.add('http://x', 'u', 'p', label: '旧名');
      await notifier.edit(0, password: 'new');
      expect(notifier.state.logins[0].label, '旧名');
    });

    test('edit clearMark=true 清空 mark', () async {
      await notifier.add(
        'http://x', 'u', 'p',
        mark: const AccountMark(colorIndex: 1),
      );
      await notifier.edit(0, clearMark: true);
      expect(notifier.state.logins[0].mark, isNull);
    });
  });

  group('迁移兼容', () {
    test('load 老格式数据(无 label/mark)→ 均为 null', () async {
      // 手写老格式密文(只有 server/username/password)
      final plaintext =
          '[{"server":"http://old","username":"u","password":"p"}]';
      final ciphertext = await storage.encrypt(plaintext);
      await prefs.setString('saved_logins', ciphertext);

      final n2 = SavedLoginsNotifier(
        prefs: prefs,
        storage: storage,
        onBaseUrlChange: (_) {},
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async {},
        onSwitchingChange: (_) {},
      );
      await n2.load();
      expect(n2.state.logins.length, 1);
      expect(n2.state.logins[0].label, isNull);
      expect(n2.state.logins[0].mark, isNull);
      expect(n2.state.logins[0].server, 'http://old');
    });
  });
}
