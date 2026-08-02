import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import '../services/api_service.dart';
import '../services/secure_storage.dart';
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

/// 同步当前账号 user_id 给 bg-service isolate。
///
/// 为什么需要:SharedPreferences 各 isolate 内 cache 独立,主 isolate login 写入
/// 不会自动同步到 bg-service isolate 的 cache。bg-service 用 stale user_id 判断
/// 「自己发的消息」会误判 → 多端 echo / 切换账号残留场景下弹自己 echo 的通知。
///
/// 调用时机:login / restoreSession / logout 完成后,以及切换账号中。
/// 空字符串 = logout,bg-service 收到后置 _myUserId=null(不让旧账号残留)。
void _syncMyUserIdToBgService(String? userId) {
  _notifyService('setMyUserId', {'user_id': userId ?? ''});
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
String? _lastKnownRefreshToken;

/// 把 access + refresh token 写入 TokenVault(refresh ONLY 在此处)
/// 并把 access 双写到 SharedPreferences(bg-service isolate 用,平台通道在 bg
/// isolate 不可靠,所以 access 走明文 prefs)。
Future<void> _persistTokens(String access, String refresh) async {
  await TokenVault.saveTokens(access, refresh);
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('token', access);
}

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
    newApi.setRefreshToken(_lastKnownRefreshToken);
    newApi.setOnTokenRefreshed(_onTokenRefreshed);
    api = newApi;
  }

  /// refresh 成功回调:持久化新 token pair 到 TokenVault + prefs。
  /// 由 ApiService 拦截器在 refresh 成功后调用(参数为 newAccess + newRefresh)。
  void _onTokenRefreshed(String access, String refresh) {
    _lastKnownToken = access;
    _lastKnownRefreshToken = refresh;
    // fire-and-forget:拦截器不 await 持久化(失败仅日志,不阻塞业务)
    _persistTokens(access, refresh).catchError((e) {
      debugPrint('[auth] refresh 持久化失败: $e');
    });
    // 更新 state.token 让 router / 业务层感知新 token
    if (state.user != null) {
      state = AuthState(user: state.user, token: access);
    }
    // 通知 bg-service 用新 token 重连 WS(若已连接则切到新 token)
    _notifyService('start', {
      'baseUrl': api.baseUrl,
      'token': access,
    });
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
      final result = await api.login(username, password);
      api.setToken(result.token);
      api.setRefreshToken(result.refreshToken);
      _lastKnownToken = result.token;
      _lastKnownRefreshToken = result.refreshToken;
      // access 双写 prefs(refresh 仅 TokenVault);保留 base_url / user_id / cached_user 走 prefs。
      await _persistTokens(result.token, result.refreshToken);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('base_url', api.baseUrl);
      // bg-service isolate 用 user_id 判断「自己发的消息不弹通知」(user-user 场景)。
      await prefs.setString('user_id', result.user.id);
      await prefs.setString('cached_user', jsonEncode(result.user.toJson()));
      await TokenVault.saveUserId(result.user.id);
      await TokenVault.saveUser(result.user);
      state = AuthState(
        user: result.user,
        token: result.token,
      );
      // 同步 user_id 给 bg-service(防 SharedPreferences 跨 isolate cache 陈旧)
      _syncMyUserIdToBgService(result.user.id);
      // 通知 service isolate 启动 WS
      _notifyService('start', {
        'baseUrl': api.baseUrl,
        'token': result.token,
      });
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  Future<void> register(String username, String password) async {
    state = state.copyWith(isLoading: true);
    try {
      final result = await api.register(username, password);
      api.setToken(result.token);
      api.setRefreshToken(result.refreshToken);
      _lastKnownToken = result.token;
      _lastKnownRefreshToken = result.refreshToken;
      await _persistTokens(result.token, result.refreshToken);
      final prefs = await SharedPreferences.getInstance();
      // register API 只返 token,需要再调 /me 拉 user(对齐 login 行为)。
      final user = await api.getMe();
      await prefs.setString('user_id', user.id);
      await prefs.setString('cached_user', jsonEncode(user.toJson()));
      await TokenVault.saveUserId(user.id);
      await TokenVault.saveUser(user);
      state = AuthState(
        user: user,
        token: result.token,
      );
      // 同步 user_id 给 bg-service(register 不调 _notifyService('start'),
      // 但 bg-service 可能下个 dispatch 就到,提前同步避免 echo 误弹通知)
      _syncMyUserIdToBgService(user.id);
    } finally {
      state = state.copyWith(isLoading: false);
    }
  }

  /// 修改当前用户密码。不需要旧密码（JWT 已验证身份）。
  /// 改密后 server 返新 token pair（旧 token 因 tokenver 自增已失效），
  /// 更新 api 实例 + 持久化到 TokenVault/prefs + 通知 bg-service。
  Future<void> changePassword(String newPassword) async {
    final result = await api.changePassword(newPassword);
    api.setToken(result.token);
    api.setRefreshToken(result.refreshToken);
    _lastKnownToken = result.token;
    _lastKnownRefreshToken = result.refreshToken;
    await _persistTokens(result.token, result.refreshToken);
    if (state.user != null) {
      state = AuthState(user: state.user, token: result.token);
    }
    _notifyService('start', {
      'baseUrl': api.baseUrl,
      'token': result.token,
    });
  }

  /// 更新当前用户资料。调用 api.updateMe，用返回值覆盖 state.user 触发 UI 刷新。
  /// nickname/bio: null=不传，""=清空；avatarUrl: null=不传，""=被忽略。
  Future<void> updateProfile({
    String? nickname,
    String? bio,
    String? avatarUrl,
  }) async {
    final user = await api.updateMe(
      nickname: nickname,
      bio: bio,
      avatarUrl: avatarUrl,
    );
    state = state.copyWith(user: user);
    // F5: 同步刷 cached_user 防止缓存陈旧(用户改 profile 后,离线兜底数据也跟着新)
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_user', jsonEncode(user.toJson()));
  }

  Future<void> restoreSession() async {
    // 优先 TokenVault(refresh_token 仅此处持久化);fallback 到 prefs 兼容
    // 旧版本升级用户(无 refresh_token,401 时直接登出)。
    // TokenVault 读异常(Android Keystore 损坏/root/刷机)不崩溃,
    // 降级到 prefs,再不行走未登录路径(见设计文档 §6.3 降级策略)。
    String? token;
    String? refresh;
    try {
      token = await TokenVault.getAccessToken();
      refresh = await TokenVault.getRefreshToken();
    } catch (e) {
      debugPrint('[auth] TokenVault 读失败,降级到 prefs: $e');
    }
    if (token == null) {
      // 兼容旧版升级:从 prefs 拉一次(无 refresh,后续 401 直接登出)。
      final prefs = await SharedPreferences.getInstance();
      token = prefs.getString('token');
    }
    if (token == null) {
      // 无 token 也算 restore 完成，必须把 isRestoring 关掉，否则 splash 永远卡住。
      state = state.copyWith(isRestoring: false);
      return;
    }
    api.setToken(token);
    api.setRefreshToken(refresh);
    _lastKnownToken = token;
    _lastKnownRefreshToken = refresh;

    // 用 /me 验证 token 仍有效并拉取用户信息。
    // 仅 401（token 失效或服务端拒绝）才清 token；其他错误（网络抖动、5xx、
    // server 切换中）保留 token，让用户下次再试，避免"网络瞬断就被踢登录"。
    bool ok = false;
    String? resolvedUserId; // 用于 restore 末尾同步给 bg-service
    try {
      final user = await api.getMe();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('base_url', api.baseUrl);
      await prefs.setString('user_id', user.id);
      // F5: 写 cached_user 供下次启动网络错兜底
      await prefs.setString('cached_user', jsonEncode(user.toJson()));
      await TokenVault.saveUserId(user.id);
      await TokenVault.saveUser(user);
      state = AuthState(
        user: user,
        token: token,
        // 显式 false 防御 copyWith 残留
        isRestoring: false,
      );
      resolvedUserId = user.id;
      ok = true;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 401 || code == 403) {
        // clearAuth 保留 aes_key:401 清掉它会让下次启动 saved_logins 密文
        // 无法解密,被 load() catch 后账号配置被静默清空(配置丢失 bug 的根因)。
        await TokenVault.clearAuth();
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('token');
        await prefs.remove('cached_user');  // F5: 鉴权失败清缓存
        state = AuthState(isRestoring: false);
        // 401/403:清 bg-service 的 _myUserId(防残留干扰下次账号)
        _syncMyUserIdToBgService(null);
      } else {
        // F5: 网络错读 cached_user 兜底
        User? cachedUser = await TokenVault.getUser();
        if (cachedUser == null) {
          // 兜底:TokenVault 没有(旧版升级),从 prefs 拉
          final prefs = await SharedPreferences.getInstance();
          final cachedJson = prefs.getString('cached_user');
          if (cachedJson != null) {
            try {
              cachedUser =
                  User.fromJson(jsonDecode(cachedJson) as Map<String, dynamic>);
            } catch (_) {
              // JSON 损坏,忽略,走未登录路径
            }
          }
        }
        // 同步刷 user_id:cached_user.id 是当前账号权威 ID,
        // 防止 prefs.user_id 历史残留(旧账号 / 切换账号中间态)干扰
        // bg-service 的 senderId==myUserId 判断。
        if (cachedUser != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('user_id', cachedUser.id);
          await prefs.setString('cached_user', jsonEncode(cachedUser.toJson()));
          resolvedUserId = cachedUser.id;
        }
        state = AuthState(
          user: cachedUser,
          // cachedUser 为 null 时 token 也设 null,router 跳 /login
          // cachedUser 非 null 时 token 保留,router 进消息页 + 离线 banner
          token: cachedUser != null ? token : null,
          isRestoring: false,
        );
        // 同步给 bg-service:cachedUser 非空 → 用 cachedUser.id;
        // cachedUser 为空(JSON 损坏)→ 清空,防残留。
        _syncMyUserIdToBgService(resolvedUserId);
      }
    } catch (_) {
      // 非 Dio 异常（如 JSON 解析错误）也保留 token，下次再试。
      state = AuthState(isRestoring: false);
    }
    // 通知 service isolate 启动 WS。放在 try-catch 外，避免 _notifyService 自身
    // 抛出的异常被上面的 catch-all 误吞导致 state 被回滚为未登录。
    if (ok) {
      // ok 路径的 user_id 同步放这里(在 _notifyService('start') 前调,
      // 确保 bg-service 收到 start 时 _myUserId 已是最新,首个 dispatch 即可正确判断 echo)
      _syncMyUserIdToBgService(resolvedUserId);
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
    // 同步清 bg-service 的 _myUserId(防残留干扰下次账号 / 切换中间态)。
    // 跟 _notifyService('stop') 顺序无关(stop 只断 WS,不读 _myUserId)。
    _syncMyUserIdToBgService(null);
    // 立即标记为已登出，让后续并发调用短路返回；
    // prefs 中的 token 异步清理，但内存 state 已变，业务侧已感知登出。
    // silent=true 保留 isSwitching,避免切换中 router 误跳 /login。
    state = AuthState(isSwitching: silent);
    _lastKnownToken = null;
    _lastKnownRefreshToken = null;
    // 先调 server 登出(黑名单 access + 删 refresh),失败不阻塞本地清理。
    // logout 接口需要 user JWT,所以必须在清 dio Authorization 头之前调。
    await api.logout();
    // 清 api 实例的 token + refresh,防在飞请求 401 触发 refresh 污染
    // (账号切换场景:旧账号在飞请求 refresh 出的新 token 会被 _onTokenRefreshed
    // 写入当前 api,污染新账号会话)。
    api.setRefreshToken(null);
    api.clearToken();
    // clearAuth 保留 aes_key:登出清掉它会让下次启动 saved_logins 密文无法解密,
    // 被 load() catch 后账号配置被静默清空(配置丢失 bug 的根因)。
    await TokenVault.clearAuth();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    await prefs.remove('cached_user');  // F5: 主动登出清缓存(对齐 401 行为,防止残留用户数据)
    // bg-service isolate 用 prefs.user_id 判断「自己发的消息不弹通知」。
    // 不清 user_id 会残留旧账号 ID,下次登录前(或网络错兜底)bg-service 收到消息
    // 会用旧 ID 比对,误判自己 echo 为对方消息而弹通知。logout 时 bg-service 已 stop,
    // 不会立即读 prefs,清掉是安全的。
    await prefs.remove('user_id');
  }
}

final apiProvider = Provider<ApiService>((ref) {
  final baseUrl = ref.watch(settingsProvider);
  final api = ApiService(baseUrl: baseUrl);
  // 新 ApiService 同步注入当前 token,避免 apiProvider 重建时
  // (settings 变化)新实例没 token 触发 401 → logout 误清登录态。
  if (_lastKnownToken != null) api.setToken(_lastKnownToken!);
  if (_lastKnownRefreshToken != null) api.setRefreshToken(_lastKnownRefreshToken);
  return api;
});

/// authProvider 不 watch apiProvider(避免 baseUrl 变化时 authProvider 重建导致 state 重置)。
/// 改为持有稳定 ApiService 引用,apiProvider 变化时通过 setApi 更新引用。
/// 401 回调 + refresh 回调在新 api 上重新注入。
final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final api = ref.read(apiProvider); // read 不是 watch,baseUrl 变不重建 notifier
  final notifier = AuthNotifier(api);
  api.setOnUnauthorized(notifier.logout);
  api.setOnTokenRefreshed(notifier._onTokenRefreshed);
  // baseUrl 变化时,只更新 notifier 内的 api 引用 + 回调,不重建 notifier
  ref.listen(apiProvider, (prev, next) {
    notifier.setApi(next);
    next.setOnUnauthorized(notifier.logout);
    next.setOnTokenRefreshed(notifier._onTokenRefreshed);
  });
  // bg-service 重连失败时通过 IPC 请求主 isolate 刷新 token。
  // bg-service 是独立 isolate,不能直接调 ApiService。主 isolate refresh 成功后
  // _onTokenRefreshed 会通过 'start' IPC 把新 token 传回 bg-service。
  if (Platform.isAndroid || Platform.isIOS) {
    FlutterBackgroundService().on('requestTokenRefresh').listen((_) {
      debugPrint('[auth] bg-service 请求 token 刷新');
      api.tryRefreshToken().then((newToken) {
        if (newToken != null) {
          debugPrint('[auth] bg-service 请求的 token 刷新成功');
        } else {
          debugPrint('[auth] bg-service 请求的 token 刷新失败(无 refresh token 或 refresh 失败)');
        }
      });
    });
  }
  return notifier;
});
