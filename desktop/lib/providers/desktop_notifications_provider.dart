// desktop/lib/providers/desktop_notifications_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 桌面通知开关:默认开启,shared_preferences 持久化。
/// 控制 core NotificationService 弹桌面系统通知的出人口(消息通知逻辑
/// 接入桌面时消费本开关;当前先行落设置态)。
class DesktopNotificationsNotifier extends StateNotifier<bool> {
  DesktopNotificationsNotifier() : super(true) {
    _restore();
  }

  static const _key = 'desktop.notifications_enabled';

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_key);
    if (v != null) state = v;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, enabled);
  }
}

final desktopNotificationsProvider =
    StateNotifierProvider<DesktopNotificationsNotifier, bool>(
  (ref) => DesktopNotificationsNotifier(),
);
