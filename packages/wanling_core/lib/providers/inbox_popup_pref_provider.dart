import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_provider.dart' show authProvider;
import 'saved_logins_provider.dart' show sharedPrefsProvider;

/// 审批/问答抽屉自动弹出开关(SharedPreferences `inbox_auto_popup_{ownerId}`)。
///
/// 纯本地偏好,按 ownerId 隔离;空 ownerId(登出/切账号中间态)恒 true 且不落盘。
/// 语义只管「自动弹」:关闭后卡片照常进收件箱队列与消息流,进会话页仍可处理。
/// ownerId 变化(切换账号)时 provider 随 authProvider 重建,读新用户存量值。
class InboxPopupPrefNotifier extends StateNotifier<bool> {
  InboxPopupPrefNotifier({
    required SharedPreferences prefs,
    required String ownerId,
  })  : _prefs = prefs,
        _key = 'inbox_auto_popup_$ownerId',
        _anonymous = ownerId.isEmpty,
        super(_initial(prefs, ownerId));

  final SharedPreferences _prefs;
  final String _key;

  /// 登出/切账号中间态不读不写。
  final bool _anonymous;

  static bool _initial(SharedPreferences prefs, String ownerId) =>
      ownerId.isEmpty
          ? true
          : (prefs.getBool('inbox_auto_popup_$ownerId') ?? true);

  /// 切换开关:同步更新 state(Host watch 立即 rebuild),再落盘。
  /// 审计 M3:同值幂等不重复 notify;写失败抛出(fail fast,禁吞)。
  Future<void> set(bool v) async {
    if (_anonymous || v == state) return;
    state = v;
    if (!await _prefs.setBool(_key, v)) {
      throw StateError('InboxPopupPref: 持久化失败 $_key=$v');
    }
  }
}

final inboxPopupPrefProvider =
    StateNotifierProvider<InboxPopupPrefNotifier, bool>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  final ownerId = ref.watch(authProvider.select((s) => s.user?.id ?? ''));
  return InboxPopupPrefNotifier(prefs: prefs, ownerId: ownerId);
});
