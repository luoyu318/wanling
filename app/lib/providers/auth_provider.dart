import 'package:dio/dio.dart' show DioException;
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import 'settings_provider.dart';

/// 向 background service isolate 发 IPC。
/// 失败不阻塞主流程（登录/登出/会话恢复），仅记录日志：
/// - 生产环境：平台插件已注册，invoke 走原生通道，不会进 catch。
/// - 测试环境：原生平台未注册，FlutterBackgroundServicePlatform.instance
///   抛 'supported for Android and iOS only'，这里吞掉。
void _notifyService(String method, [Map<String, dynamic>? args]) {
  try {
    FlutterBackgroundService().invoke(method, args);
  } catch (e) {
    debugPrint('[auth] service IPC "$method" 失败: $e');
  }
}

/// 模块级 token 缓存：所有 ApiService 实例创建时同步注入。
///
/// 为什么需要这个：
/// apiProvider 是 lazy，settings 变化时会重建（新 ApiService 无 token）。
/// authProvider.listen(apiProvider) 的 setApi 回调在 microtask 中触发，
/// 时序上可能晚于其他 provider（如 conversationProvider）拿到新 api 发起请求，
/// 导致 401 → 拦截器 logout → 误清登录态。
/// 模块级缓存让任何 ApiService 实例创建时同步带 token，避免时序竞态。
String? _lastKnownToken;

class AuthState {
  final User? user;
  final String? token;
  final bool isLoading;
  /// 启动期 restoreSession 是否进行中。true 时 router 把所有路径 redirect 到 /splash，
  /// 避免 restoreSession 完成前的瞬间因 isAuthenticated=false 误跳 /login。
  /// restoreSession 完成后永远保持 false。
  final bool isRestoring;
  /// 账号切换进行中。切换 = logout→login 两步,中间会短暂处于未登录态,
  /// 若不标记会让 router 误跳 /login 造成"我的→登录页闪现→消息页"两次跳转。
  /// true 时 router 视同已登录,不触发 redirect,切换全程页面稳定。
  final bool isSwitching;

  AuthState({
    this.user,
    this.token,
    this.isLoading = false,
    this.isRestoring = false,
    this.isSwitching = false,
  });

  AuthState copyWith({
    User? user,
    String? token,
    bool? isLoading,
    bool? isRestoring,
    bool? isSwitching,
  }) =>
      AuthState(
        user: user ?? this.user,
        token: token ?? this.token,
        isLoading: isLoading ?? this.isLoading,
        isRestoring: isRestoring ?? this.isRestoring,
        isSwitching: isSwitching ?? this.isSwitching,
      );

  bool get isAuthenticated => token != null;
}

class AuthNotifier extends StateNotifier<AuthState> {
  ApiService api;

  /// 初始 isRestoring=true，等 main 显式调用 restoreSession 完成后置 false。
  /// 这样 router 在 restoreSession 进行中可以显示 splash，避免首帧渲染时
  /// 闪现 /login（旧实现 main 里 await restoreSession，会阻塞 runApp 一个网络 RTT）。
  AuthNotifier(this.api) : super(AuthState(isRestoring: true));

  /// baseUrl 变化时更新 api 引用(不重建 notifier,state 保持)。
  /// token 和 user 信息迁移到新 api(新 baseUrl + 同 token)。
  void setApi(ApiService newApi) {
    final token = state.token;
    if (token != null) newApi.setToken(token);
    api = newApi;
  }

  /// 标记切换账号进行中。SavedLoginsNotifier.switchTo 调用,
  /// 让 router 在 logout→login 中间态视同已登录(见 router redirect)。
  void setSwitching(bool switching) {
    if (state.isSwitching == switching) return;
    state = state.copyWith(isSwitching: switching);
  }

  Future<void> login(String username, String password) async {
    state = state.copyWith(isLoading: true);
    try {
      final data = await api.login(username, password);
      api.setToken(data['token']);
      _lastKnownToken = data['token'];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', data['token']);
      await prefs.setString('base_url', api.baseUrl);
      // bg-service isolate 用 user_id 判断「自己发的消息不弹通知」(user-user 场景)。
      final user = User.fromJson(data['user']);
      await prefs.setString('user_id', user.id);
      state = AuthState(
        user: user,
        token: data['token'],
      );
      // 通知 service isolate 启动 WS
      _notifyService('start', {
        'baseUrl': api.baseUrl,
        'token': data['token'],
      });
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> register(String username, String password) async {
    state = state.copyWith(isLoading: true);
    try {
      final data = await api.register(username, password);
      api.setToken(data['token']);
      _lastKnownToken = data['token'];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('token', data['token']);
      final user = User.fromJson(data['user']);
      await prefs.setString('user_id', user.id);
      state = AuthState(
        user: user,
        token: data['token'],
      );
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  /// 修改当前用户密码。不需要旧密码（JWT 已验证身份）。
  /// 改密后当前 token 仍有效，由 UI 决定是否重登。
  Future<void> changePassword(String newPassword) async {
    await api.changePassword(newPassword);
  }

  /// 更新当前用户资料。调用 api.updateMe，用返回值覆盖 state.user 触发 UI 刷新。
  /// nickname/bio: null=不传，""=清空；avatarUrl: null=不传，""=被忽略。
  Future<void> updateProfile({
    String? nickname,
    String? bio,
    String? avatarUrl,
  }) async {
    final data = await api.updateMe(
      nickname: nickname,
      bio: bio,
      avatarUrl: avatarUrl,
    );
    state = state.copyWith(user: User.fromJson(data));
  }

  Future<void> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    if (token == null) {
      // 无 token 也算 restore 完成，必须把 isRestoring 关掉，否则 splash 永远卡住。
      state = state.copyWith(isRestoring: false);
      return;
    }
    api.setToken(token);
    _lastKnownToken = token;

    // 用 /me 验证 token 仍有效并拉取用户信息。
    // 仅 401（token 失效或服务端拒绝）才清 token；其他错误（网络抖动、5xx、
    // server 切换中）保留 token，让用户下次再试，避免"网络瞬断就被踢登录"。
    bool ok = false;
    try {
      final userData = await api.getMe();
      await prefs.setString('base_url', api.baseUrl);
      final user = User.fromJson(userData);
      await prefs.setString('user_id', user.id);
      state = AuthState(
        user: user,
        token: token,
        // 显式 false 防御 copyWith 残留
        isRestoring: false,
      );
      ok = true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        await prefs.remove('token');
      }
      // 其他情况保留 token，下次启动再试。state 保持未登录（token 在 prefs 但内存无）。
      state = AuthState(isRestoring: false);
    } catch (_) {
      // 非 Dio 异常（如 JSON 解析错误）也保留 token，下次再试。
      state = AuthState(isRestoring: false);
    }
    // 通知 service isolate 启动 WS。放在 try-catch 外，避免 _notifyService 自身
    // 抛出的异常被上面的 catch-all 误吞导致 state 被回滚为未登录。
    if (ok) {
      _notifyService('start', {
        'baseUrl': api.baseUrl,
        'token': token,
      });
    }
  }

  /// 登出。
  ///
  /// [silent]：切换账号场景用 true。普通登出会广播 AuthState()（未登录），
  /// 触发 router 跳 /login。但切换 = logout→login 两步，中间若广播未登录态
  /// 会让 router 误跳 /login 再被拉回，造成页面闪烁两次。
  /// silent=true 时保留 isSwitching 标志，router 视同已登录不跳转，
  /// 切换全程页面稳定。
  Future<void> logout({bool silent = false}) async {
    // 幂等短路：并发 401 风暴时（多个 in-flight 请求同时收到 401），
    // 第一个调用进入后会立即把 state 置空，后续调用看到未认证直接返回，
    // 避免重复广播 AuthState 变化触发 router/wsProvider 等订阅方多次响应。
    // 注意：必须在 await 之前抢先标记，否则单线程事件循环下后续调用仍能越过 if 检查。
    if (!state.isAuthenticated) return;
    // 通知 service isolate 停止 WS（保留进程，下次登录直接重启 WS）
    _notifyService('stop');
    // 立即标记为已登出，让后续并发调用短路返回；
    // prefs 中的 token 异步清理，但内存 state 已变，业务侧已感知登出。
    // silent=true 保留 isSwitching,避免切换中 router 误跳 /login。
    state = AuthState(isSwitching: silent);
    _lastKnownToken = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
  }
}

final apiProvider = Provider<ApiService>((ref) {
  final baseUrl = ref.watch(settingsProvider);
  final api = ApiService(baseUrl: baseUrl);
  // 新 ApiService 同步注入当前 token，避免 apiProvider 重建时
  // （settings 变化）新实例没 token 触发 401 → logout 误清登录态。
  if (_lastKnownToken != null) api.setToken(_lastKnownToken!);
  return api;
});

/// authProvider 不 watch apiProvider(避免 baseUrl 变化时 authProvider 重建导致 state 重置)。
/// 改为持有稳定 ApiService 引用,apiProvider 变化时通过 setApi 更新引用。
/// 401 回调在新 api 上重新注入。
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final api = ref.read(apiProvider); // read 不是 watch,baseUrl 变不重建 notifier
  final notifier = AuthNotifier(api);
  api.setOnUnauthorized(notifier.logout);
  // baseUrl 变化时,只更新 notifier 内的 api 引用 + 401 回调,不重建 notifier
  ref.listen(apiProvider, (prev, next) {
    notifier.setApi(next);
    next.setOnUnauthorized(notifier.logout);
  });
  return notifier;
});
