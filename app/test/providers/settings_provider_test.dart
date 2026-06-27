import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/providers/settings_provider.dart';

void main() {
  group('SettingsNotifier.setBaseUrl', () {
    test('state 在 Future 完成前已同步更新为新值', () async {
      // 这是切换账号竞态修复(B1)的关键不变量:
      // select() 通过同步回调 fire-and-forget 调 setBaseUrl,
      // 紧接着的同步代码(如 apiProvider 重建)必须读到新 baseUrl,
      // 不能等 prefs 异步写完才更新 state。
      SharedPreferences.setMockInitialValues({'api_base_url': 'http://old'});
      final notifier = SettingsNotifier();
      await notifier.load();

      expect(notifier.state, 'http://old');

      // 触发但不 await,模拟 select 回调的 fire-and-forget
      final future = notifier.setBaseUrl('http://new');
      // 关键断言:future 还没完成,state 已是新值
      expect(notifier.state, 'http://new');

      await future; // 确保 prefs 写入完成,无未捕获异常
      expect(notifier.state, 'http://new');
    });

    test('prefs 在 Future 完成后已持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final notifier = SettingsNotifier();
      await notifier.load();
      await notifier.setBaseUrl('http://persisted');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('api_base_url'), 'http://persisted');
    });
  });
}
