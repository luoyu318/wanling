// desktop/lib/shell/window_actions.dart
import 'dart:async';

import 'package:window_manager/window_manager.dart';

/// 窗口操作抽象:生产 WindowManagerActions(直通 window_manager),
/// 测试传 fake(不依赖真窗口)。
/// isMaximized 为 Future:window_manager 查询窗口状态本身是异步通道调用。
abstract class WindowActions {
  Future<void> minimize();
  Future<void> toggleMaximize();
  Future<void> close();
  Future<void> dragWindow();
  Future<bool> get isMaximized;
  Stream<void> get onStateChanged;
}

/// 生产实现:直通 window_manager。
/// 桥接 WindowListener 的 maximize/unmaximize 回调为广播流;
/// app 级单例,生命周期与窗口一致,无需 dispose。
class WindowManagerActions extends WindowListener implements WindowActions {
  final StreamController<void> _stateEvents = StreamController<void>.broadcast();

  WindowManagerActions() {
    windowManager.addListener(this);
  }

  @override
  void onWindowMaximize() => _stateEvents.add(null);

  @override
  void onWindowUnmaximize() => _stateEvents.add(null);

  @override
  Future<void> minimize() => windowManager.minimize();

  @override
  Future<void> toggleMaximize() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Future<void> close() => windowManager.close();

  @override
  Future<void> dragWindow() => windowManager.startDragging();

  @override
  Future<bool> get isMaximized => windowManager.isMaximized();

  @override
  Stream<void> get onStateChanged => _stateEvents.stream;
}
