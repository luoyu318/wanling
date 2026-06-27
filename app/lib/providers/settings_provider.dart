import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsNotifier extends StateNotifier<String> {
  static const _key = 'api_base_url';
  static const _default = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:18008',
  );

  SettingsNotifier() : super(_default);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved != null) state = saved;
  }

  /// 设置 baseUrl:先同步更新 state(让依赖方立即可见新值),再异步持久化。
  ///
  /// 同步更新 state 是切换账号竞态修复的关键:select() 通过同步回调
  /// fire-and-forget 调用本方法,紧接着的 apiProvider 重建需读到新 baseUrl,
  /// 不能等 prefs 异步写完。持久化仍由返回的 Future 保证完成。
  Future<void> setBaseUrl(String url) async {
    state = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, url);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, String>((ref) {
  final notifier = SettingsNotifier();
  notifier.load();
  return notifier;
});
