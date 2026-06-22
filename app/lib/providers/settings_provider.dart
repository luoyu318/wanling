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

  Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, url);
    state = url;
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, String>((ref) {
  final notifier = SettingsNotifier();
  notifier.load();
  return notifier;
});
