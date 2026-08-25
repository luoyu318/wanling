import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 规范化用户输入的 server 地址,修复常见误输(返回空串=无效):
/// - `localhost:18008` → `http://localhost:18008`(无 scheme 补 http://)
/// - `http:localhost:18008` → `http://localhost:18008`(scheme 漏 // 补全)
/// - 去尾部 `/`;解析不出 host 判无效。
String normalizeBaseUrl(String raw) {
  var v = raw.trim();
  if (v.isEmpty) return '';
  final hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(v);
  if (!hasScheme) {
    // 剥掉可能存在的 scheme: 残留(http:host:port 形态)再补 http://
    v = v.replaceFirst(RegExp('^[a-zA-Z][a-zA-Z0-9+.\\-]*:'), '');
    v = 'http://$v';
  }
  while (v.endsWith('/')) {
    v = v.substring(0, v.length - 1);
  }
  final uri = Uri.tryParse(v);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
  return v;
}

class SettingsNotifier extends StateNotifier<String> {
  static const _key = 'api_base_url';
  static const _default = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://localhost:18008',
  );

  SettingsNotifier() : super(_default);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    // 存量坏数据修复(如 http:localhost:18008):load 时规范化回写。
    if (saved != null) {
      final fixed = normalizeBaseUrl(saved);
      state = fixed.isNotEmpty ? fixed : _default;
      if (fixed.isNotEmpty && fixed != saved) {
        await prefs.setString(_key, state);
      }
    }
  }

  /// 设置 baseUrl:先同步更新 state(让依赖方立即可见新值),再异步持久化。
  ///
  /// 同步更新 state 是切换账号竞态修复的关键:select() 通过同步回调
  /// fire-and-forget 调用本方法,紧接着的 apiProvider 重建需读到新 baseUrl,
  /// 不能等 prefs 异步写完。持久化仍由返回的 Future 保证完成。
  Future<void> setBaseUrl(String url) async {
    final fixed = normalizeBaseUrl(url);
    // 无效输入不落 state(保持旧值):调用方 UI 应先行校验给用户反馈,
    // 这里兜底防坏数据进 provider 树(apiProvider 构造会抛,灰屏全挂)。
    if (fixed.isEmpty) return;
    state = fixed;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, fixed);
  }
}

final settingsProvider = StateNotifierProvider<SettingsNotifier, String>((ref) {
  final notifier = SettingsNotifier();
  notifier.load();
  return notifier;
});
