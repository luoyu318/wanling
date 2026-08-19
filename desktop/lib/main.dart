import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/services/notification_service.dart';
import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面通知初始化(Windows/Linux settings 由 core notification_service 处理)
  await NotificationService.instance.init();
  // 窗口基础尺寸:linux 下用 gdk 初始化参数,windows 由 runner 处理,M3 换 window_manager
  runApp(const ProviderScope(child: WanlingDesktopApp()));
}
