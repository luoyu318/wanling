import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/local_message_store_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/services/notification_service.dart';
import 'package:window_manager/window_manager.dart';
import 'app.dart';
import 'rendering/aggregate_card_renderer.dart';
import 'shell/app_canvas.dart' show windowActionsProvider;
import 'shell/window_actions.dart';

/// 桌面启动诊断日志(对齐 app 壳):逐里程碑追加写 exe 同目录 wanling-startup.log,
/// GUI 应用无控制台可看,文件日志是唯一线索源。IO 失败静默吞(诊断不阻主流程)。
void _desktopStartupLog(String msg) {
  try {
    final dir = File(Platform.resolvedExecutable).parent;
    final f = File('${dir.path}${Platform.pathSeparator}wanling-startup.log');
    f.writeAsStringSync(
      '${DateTime.now().toIso8601String()} $msg\n',
      mode: FileMode.append,
    );
  } catch (_) {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _desktopStartupLog('main: binding initialized');
  // 无边框窗口初始化:失败不阻启动(fallback 系统装饰,标题栏按钮隐藏)。
  // WindowManagerActions 全局单例(无 close 设计,生命周期与窗口一致),
  // overrideWithValue 注入 TitleBar 消费。
  WindowActions? windowActions;
  try {
    await windowManager.ensureInitialized();
    // 不用 TitleBarStyle.hidden:其 Windows 实现会在 WM_NCCALCSIZE 预留
    // 8px 非客户区做系统缩放边,而窗口类无背景刷 → 该区域涂黑成黑边
    // (window_manager_plugin.cc NCCALCSIZE 分支)。改 setAsFrameless()
    // 客户区铺满整窗由 Flutter 自绘,缩放走 WindowResizeEdges 热区。
    const opts = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(800, 600),
      center: true,
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setAsFrameless();
      await windowManager.show();
    });
    windowActions = WindowManagerActions();
    _desktopStartupLog('main: window_manager ready');
  } catch (e) {
    _desktopStartupLog('main: window_manager init fail: $e');
  }
  // 首帧里程碑:区分「卡在 runApp 前」vs「渲染后无窗口/被遮」。
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => _desktopStartupLog('main: first frame rendered'),
  );
  // 消息内容渲染注册表:Text/Markdown/Image/File/Card/Aggregate 等内置 renderer。
  registerBuiltinRenderers();
  // 桌面版聚合卡覆盖注册:外壳透明无边框无阴影,与聊天背景融合
  // (app 端注册表不受影响,仍用 core 白卡样式;差异见 desktop renderer 注释)。
  ContentRendererRegistry.register(
      MsgType.aggregateCard, const DesktopAggregateCardRenderer());
  // 桌面通知初始化(Windows/Linux settings 由 core notification_service 处理)
  await NotificationService.instance.init();
  // 注入已 load 的 SharedPreferences(savedLogins 依赖同步实例),
  // 再按 app 壳同序恢复:settings → savedLogins → 登录态。
  // restoreSession 完成后才 runApp,首帧即最终登录态,无 /login 闪现。
  final prefs = await SharedPreferences.getInstance();
  _desktopStartupLog('main: prefs loaded');
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      windowActionsProvider.overrideWithValue(windowActions),
    ],
  );
  await container.read(settingsProvider.notifier).load();
  await container.read(savedLoginsProvider.notifier).load();
  await container.read(authProvider.notifier).restoreSession();

  // 已登录时等 LocalMessageStore ready 再 runApp(对齐 app 壳保障):否则冷启动
  // 亚秒窗口内点开会话,chatProvider 首建拿到 store=null,store ready 触发
  // provider 重建,旧 ChatNotifier 在网络 await 后写 state 抛 Bad state
  // (unhandled zone error)。未登录时跳过(uid=null 会让 provider 抛
  // StateError 进 error state)。10s 超时保护:store 卡死不该卡登录页。
  final uid = container.read(authProvider).user?.id;
  if (uid != null) {
    // autoDispose provider 无 listener 时会被调度回收,container.read(.future)
    // 不保活;listen 持有 subscription,runApp 后首帧(chatProvider 已 watch
    // 上)再关闭。
    final keepAliveSub = container.listen(localMessageStoreProvider, (_, _) {});
    try {
      await container
          .read(localMessageStoreProvider.future)
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      debugPrint('[main] localMessageStore open 超时(10s),降级继续启动');
    } catch (e) {
      // store open 失败静默 runApp,后续 chatProvider 拿到 null store 降级
      // (不持久化、Resume last_seq 走内存兜底)。
      debugPrint('[main] localMessageStore open fail: $e');
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => keepAliveSub.close());
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const WanlingDesktopApp(),
    ),
  );
  _desktopStartupLog('main: runApp done');
}
