import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'providers/auth_provider.dart';
import 'providers/saved_logins_provider.dart';
import 'providers/settings_provider.dart';
import 'rendering/builtin_renderers.dart';
import 'router.dart';
import 'services/background_chat_service.dart';
import 'services/notification_service.dart';
import 'utils/app_lifecycle_observer.dart';
import 'utils/permission_helper.dart';
import 'utils/secure_storage.dart';

/// 全局 lifecycle observer（main 中创建一次）。
late final AppLifecycleObserver _lifecycleObserver;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 注册内置消息内容渲染器（text/markdown/image/file）。
  // 新增 HTML/卡片时在 registerBuiltinRenderers 内追加。
  registerBuiltinRenderers();

  // 1. 初始化本地通知
  await NotificationService.instance.init();

  // 设置通知点击回调：暖启动时跳到对应 ChatPage
  NotificationService.instance.onTap = (payload) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    GoRouter.of(ctx).push(
      '/chat/${payload.convId}?agentId=${payload.agentId}',
    );
  };

  // 2. 配置 + 启动 background service（前台服务）
  _setupBackgroundService();

  // 3. ProviderContainer：settingsProvider 必须 await 后再 restoreSession
  // 否则 settingsProvider 默认 localhost，apiProvider 用错误 baseUrl，
  // restoreSession 的 /me 会失败导致 token 被清/丢登录态。
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      // 注入已 load 的 SharedPreferences,savedLoginsProvider 用同步接口
      sharedPrefsProvider.overrideWithValue(prefs),
    ],
  );
  await container.read(settingsProvider.notifier).load();

  // 加载 savedLogins(解密登录组合 + 恢复上次选中 + 同步 baseUrl)
  await container.read(savedLoginsProvider.notifier).load();

  // service 自恢复需要从 SharedPreferences 读 base_url 和 token。
  // 在 restoreSession 之前写，确保 service 重启时有可用凭据。
  final baseUrl = container.read(settingsProvider);
  await prefs.setString('base_url', baseUrl);

  await container.read(authProvider.notifier).restoreSession();

  // 4. 注册 lifecycle observer（IPC 通知 service 前后台切换 + 首次后台引导电池白名单）
  _lifecycleObserver = AppLifecycleObserver(navigatorKey: navigatorKey);
  _lifecycleObserver.attach();

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const MyApp(),
    ),
  );
}

void _setupBackgroundService() {
  final service = FlutterBackgroundService();
  service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundChatServiceEntry,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'wanling_service',
      initialNotificationTitle: '万灵',
      initialNotificationContent: '唤灵 · 即应',
      foregroundServiceNotificationId: 8888,
      // remoteMessaging 是 Android 14+ 后台启动豁免类型，
      // 供 IM 类应用保活 WS 接收消息。
      // dataSync 作为旧版本兼容。
      foregroundServiceTypes: [
        AndroidForegroundType.remoteMessaging,
        AndroidForegroundType.dataSync,
      ],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
    ),
  );
  service.startService();
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  @override
  void initState() {
    super.initState();
    // 首帧渲染后申请通知权限（首次启动）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      PermissionHelper.requestNotification(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: '万灵',
      // 国际化：固定中文。
      // 设计决策：App 文案全部硬编码中文，无英文化基础，故不引入 intl 多语言框架，
      // 直接固定 locale=zh + supportedLocales=[zh]。
      // 这样做有两个作用：
      // 1. Flutter 内置 Material 组件（日期/时间选择器等）通过 GlobalMaterialLocalizations
      //    显示中文；
      // 2. wechat_assets_picker 的 assetPickerTextDelegateFromLocale(locale) 拿到 zh locale，
      //    命中简体中文 textDelegate，相册选择器显示中文（否则会因 supportedLocales 默认
      //    只含 en 被解析成英文，显示 recent/preview/confirm）。
      locale: const Locale('zh'),
      supportedLocales: const [
        Locale('zh'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF07C160), // 品牌主色绿
        useMaterial3: true,
      ),
      routerConfig: router,
    );
  }
}
