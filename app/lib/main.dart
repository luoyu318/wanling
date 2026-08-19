import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/services/background_bridge.dart'
    show backgroundServiceIpc;

import 'providers/auth_provider.dart';
import 'providers/local_message_store_provider.dart';
import 'providers/saved_logins_provider.dart';
import 'providers/settings_provider.dart';
import 'rendering/builtin_renderers.dart';
import 'router.dart';
import 'theme/app_colors.dart';
import 'services/background_chat_service.dart';
import 'services/notification_service.dart';
import 'utils/app_lifecycle_observer.dart';
import 'utils/permission_helper.dart';

/// 全局 lifecycle observer（main 中创建一次）。
late final AppLifecycleObserver _lifecycleObserver;

/// 配置全局 ImageCache 容量上限。
///
/// Flutter 默认 1000 张 / 100MB。聊天场景头像 + 消息图片密集，且各加载点已用
/// memCacheWidth 把单张缩略图压到几十 KB，但仍可能在大段历史消息里超过默认
/// 上限触发 LRU 淘汰，导致返回页面 / 滚动时「闪占位符再出图」。
///
/// 调到 500 张 / 200MB：配合 memCacheWidth（缩略图每张数十 KB，画廊原图按需），
/// 200MB 可容纳数百张缩略图稳定驻留内存，长会话滚动 / 二级页返回均同步命中。
/// 必须在 runApp 前设置（runApp 后首帧才初始化 imageCache 为时已晚）。
void _configureImageCache() {
  PaintingBinding.instance.imageCache.maximumSize = 500;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 200 * 1024 * 1024;
}

/// 桌面启动诊断日志(spike 调试用,定位 Windows「有进程无窗口」):
/// 逐里程碑追加写 exe 同目录 wanling-startup.log,GUI 应用无控制台可看,
/// 文件日志是唯一线索源。IO 失败静默吞(诊断工具绝不影响主流程)。
/// Android/iOS 跳过(有 adb logcat,且避免写存储权限)。
void _desktopStartupLog(String msg) {
  if (Platform.isAndroid || Platform.isIOS) return;
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

  // 首帧里程碑:区分「卡在 runApp 前」vs「渲染后无窗口/被遮」。
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => _desktopStartupLog('main: first frame rendered'),
  );

  // 调优全局图片内存缓存上限（runApp 前设置才生效）。
  _configureImageCache();

  // 注册内置消息内容渲染器（text/markdown/image/file）。
  // 新增 HTML/卡片时在 registerBuiltinRenderers 内追加。
  registerBuiltinRenderers();

  // 1. 初始化本地通知
  await NotificationService.instance.init();

  // 设置通知点击回调：暖启动时跳到对应 ChatPage
  NotificationService.instance.onTap = (payload) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    // 智能单例：栈顶已是 ChatPage 则 replace（避免 ChatPage 叠加，也避免
    // setActiveConv 竞态——旧 ChatPage dispose + 新 ChatPage initState 顺序错乱）；
    // 否则正常 push（保留当前页面层级，如从设置页点通知返回仍回设置页）。
    final router = GoRouter.of(ctx);
    // 用 routerDelegate.currentConfiguration 拿真实栈状态，
    // routeInformationProvider 在通知唤起的过渡态可能未同步。
    // 栈顶 route 的 path（如 /chat/xxx 或 / 或 /settings）。
    final stack = router.routerDelegate.currentConfiguration;
    final topPath = stack.isNotEmpty ? stack.last.matchedLocation : '';
    final isViewingChat = topPath.startsWith('/chat/');
    final target = '/chat/${payload.convId}?agentId=${payload.agentId}';
    if (isViewingChat) {
      // ChatPage 是 push 出来的栈帧（基础 location 仍是 /），不能用 replace
      // （replace 会替换整个路由目标 URI，不替换 push 栈帧，导致栈仍叠加）。
      // pushReplacement 专门替换栈顶 push 帧：[列表,黑羽] → [列表,白羽]。
      router.pushReplacement(target);
    } else {
      router.push(target);
    }
  };

  // 2. 配置 + 启动 background service（前台服务）
  _setupBackgroundService();
  _desktopStartupLog('main: bg-service setup done');

  // 注入 bg-service IPC 桥接(core 层 providers 经 notifyService 调用)
  backgroundServiceIpc = (method, [args]) => _notifyBgServiceIpc(method, args);

  // 3. ProviderContainer：settingsProvider 必须 await 后再 restoreSession
  // 否则 settingsProvider 默认 localhost，apiProvider 用错误 baseUrl，
  // restoreSession 的 /me 会失败导致 token 被清/丢登录态。
  final prefs = await SharedPreferences.getInstance();
  _desktopStartupLog('main: prefs loaded');
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

  // F4: 已登录时等 LocalMessageStore ready 再 runApp。否则 wsProvider 启动时
  // localMessageStoreProvider 仍在 loading,注入 store=null,hello 分支 Resume
  // last_seq 走内存兜底(进程被杀场景丢失断线期间消息)。
  // 未登录时跳过(uid=null 会让 store provider 抛 StateError 进入 error state)。
  final uid = container.read(authProvider).user?.id;
  if (uid != null) {
    // autoDispose provider 在「无 listener」时会被调度回收。container.read(.future)
    // 用的是 read 不保活;runApp 前也没有 widget watch store,导致 open() 的 async
    // 让出期间 provider 被 dispose,随后 ref.onDispose 抛
    // "Cannot call onDispose after a provider was dispose"。
    // 用 listen 持有 subscription 保活,runApp 后首帧(wsProvider 已 watch 上)再关闭。
    final keepAliveSub = container.listen(localMessageStoreProvider, (_, _) {});
    try {
      await container.read(localMessageStoreProvider.future);
    } catch (e) {
      // F4 known gap:store open 失败时静默 runApp,后续 wsProvider/chatProvider
      // 拿到 null store 会降级(不持久化、Resume last_seq=null,断线期间消息丢失)。
      // F7 实施时改为错误字段 + UI banner 提示用户(目前用户无感知)。
      debugPrint('[main] localMessageStore open fail: $e');
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => keepAliveSub.close());
    }
  }

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
  // flutter_background_service 仅支持 Android/iOS(Android 前台服务保活机制)。
  // desktop 端无需保活且插件会抛 UnsupportedError,跳过。
  if (!Platform.isAndroid && !Platform.isIOS) return;
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
        colorSchemeSeed: AppColors.accentGreen, // 品牌主色绿
        useMaterial3: true,
        // 统一页面背景灰：避免每个 Scaffold 自定义。M3 默认 surface 会带绿色 seed
        // 派生的浅色，与 ProfilePage 等显式 #EDEDED 不一致。
        scaffoldBackgroundColor: AppColors.pageBgStandard,
        // 统一 AppBar 白底黑字：避免每个子页面 AppBar 走 M3 默认（浅绿底）。
        // surfaceTintColor=transparent 去掉 M3 的彩色 tint 阴影，保纯白。
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.appBarBg,
          foregroundColor: AppColors.appBarFg,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      routerConfig: router,
    );
  }
}

/// bg-service IPC 壳侧实现:桌面跳过,移动端 invoke,失败仅日志。
void _notifyBgServiceIpc(String method, [Map<String, dynamic>? args]) {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  try {
    FlutterBackgroundService().invoke(method, args);
  } catch (e) {
    debugPrint('[bg-bridge] IPC "$method" 失败: $e');
  }
}
