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
  }

  void detach() {
    WidgetsBinding.instance.removeObserver(this);
  }
}
