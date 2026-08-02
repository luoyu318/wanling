import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/notification_service.dart';
import '../widgets/feedback/app_dialog.dart';

/// 权限相关 helper：通知权限申请、电池优化白名单、应用详情跳转。
///
/// HyperOS 不能自动加白名单（必须用户手动），这里通过系统标准 intent
/// 尽量引导到最近设置页。
class PermissionHelper {
  static const _prefsKeyNotifAsked = 'perm_notif_asked';
  static const _prefsKeyBatteryAsked = 'perm_battery_asked';

  /// 申请通知权限。首次启动调用。
  /// 返回 true 表示已授权。
  static Future<bool> requestNotification(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyAsked = prefs.getBool(_prefsKeyNotifAsked) ?? false;

    final granted = await NotificationService.instance.requestPermissions();
    await prefs.setBool(_prefsKeyNotifAsked, true);

    if (!granted && !alreadyAsked && context.mounted) {
      await showAppDialog(
        context: context,
        title: '通知权限未开启',
        content: const Text('不开启通知权限将无法在后台收到 agent 消息。是否现在去设置？'),
        cancelText: '稍后',
        confirmText: '去设置',
        onConfirm: () => openAppNotificationSettings(),
      );
    }
    return granted;
  }

  /// 首次进入后台时提示用户加电池白名单 + 自启动。
  static Future<void> maybePromptBatteryOptimization(
      BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final alreadyAsked = prefs.getBool(_prefsKeyBatteryAsked) ?? false;
    if (alreadyAsked) return;
    await prefs.setBool(_prefsKeyBatteryAsked, true);

    if (!context.mounted) return;
    await showAppDialog(
      context: context,
      title: '后台接收设置',
      content: const Text(
        '为了在 APP 后台或锁屏时仍能收到 agent 消息，'
        '请开启「自启动」并将电池策略设为「无限制」。',
      ),
      cancelText: '稍后',
      confirmText: '去设置',
      onConfirm: () => openBatteryOptimizationSettings(),
    );
  }

  /// 跳到 APP 自身的通知设置页（系统设置）。
  /// permission_handler 的 openAppSettings() 跳到应用详情页（含通知入口）。
  static Future<void> openAppNotificationSettings() async {
    await openAppSettings();
  }

  /// 申请电池优化白名单（弹系统 dialog 直接加白名单）。
  static Future<void> openBatteryOptimizationSettings() async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    debugPrint('ignoreBatteryOptimizations status: $status');
  }
}
