import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import 'permission_helper.dart';

/// 监听 APP 前后台切换，IPC 通知 service isolate。
///
/// resumed = APP 在前台；paused/inactive/hidden/detached = 后台。
/// service 默认 `_appInForeground=false`（保守），首次启动即可弹通知，
/// 所以这里只在状态变化时调用，不做初始化同步。
///
/// 首次进入后台时调用 `PermissionHelper.maybePromptBatteryOptimization`
/// 引导用户开电池白名单（HyperOS 必备）。
class AppLifecycleObserver extends WidgetsBindingObserver {
  final _service = FlutterBackgroundService();
  /// 用 navigatorKey 拿 context 弹 dialog。由 main.dart 在 attach 时注入。
  final GlobalKey<NavigatorState> navigatorKey;
  bool _batteryPromptShownOnce = false;

  AppLifecycleObserver({required this.navigatorKey});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 桌面平台无 bg-service(见 attach 注释),跳过 IPC
    if (!Platform.isAndroid && !Platform.isIOS) return;
    final isForeground = state == AppLifecycleState.resumed;
    _service.invoke('setAppLifecycle', {
      'state': isForeground ? 'foreground' : 'background',
    });

    // 首次进后台提示开电池白名单。用本地标志位防止本次会话内多次弹（SharedPreferences
    // 标志位在 PermissionHelper 内防止跨会话重复）。
    if (!isForeground && !_batteryPromptShownOnce) {
      _batteryPromptShownOnce = true;
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        PermissionHelper.maybePromptBatteryOptimization(ctx);
      }
    }
  }

  /// 注册到 WidgetsBinding。
  void attach() {
    WidgetsBinding.instance.addObserver(this);
    // 桌面平台无 bg-service(flutter_background_service 仅 Android/iOS),
    // 桌面进程常驻,前台同步无意义,跳过所有 service IPC。
    if (!Platform.isAndroid && !Platform.isIOS) return;
    // 立即把当前 lifecycle 状态 IPC 给 bg-service isolate,作为初始同步。
    // observer.didChangeAppLifecycleState 只在状态变化时触发,APP 启动后
    // 一直前台(没切过后台)的话 isolate 的 _appInForeground 永远是默认值,
    // 导致"用户在会话里仍弹通知"—— attach 时同步一次堵这个口子。
    // lifecycleState 在 attach 之前可能为 null(APP 还没经历任何 lifecycle 事件),
    // 此时按 IM 启动惯例假设前台,跟 bg-service 默认值一致。
    final currentState = WidgetsBinding.instance.lifecycleState;
    final isForeground = currentState == null ||
        currentState == AppLifecycleState.resumed;
    _service.invoke('setAppLifecycle', {
      'state': isForeground ? 'foreground' : 'background',
    });
  }

  void detach() {
    WidgetsBinding.instance.removeObserver(this);
  }
}
