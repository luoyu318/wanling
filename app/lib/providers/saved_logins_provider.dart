import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/account_mark.dart';
import '../models/saved_login.dart';
import '../utils/secure_storage.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';

const _kSavedLoginsKey = 'saved_logins';
const _kLastLoginIndexKey = 'last_login_index';

class SavedLoginsState {
  final List<SavedLogin> logins;
  final int selectedIndex;

  const SavedLoginsState({
    this.logins = const [],
    this.selectedIndex = -1,
  });

  SavedLoginsState copyWith({
    List<SavedLogin>? logins,
    int? selectedIndex,
  }) =>
      SavedLoginsState(
        logins: logins ?? this.logins,
        selectedIndex: selectedIndex ?? this.selectedIndex,
      );

  /// 当前选中的 SavedLogin(无选中返回 null)。
  SavedLogin? get selected =>
      selectedIndex >= 0 && selectedIndex < logins.length
          ? logins[selectedIndex]
          : null;

  bool get isEmpty => logins.isEmpty;
}

/// 管理本地保存的登录组合列表 + 当前选中项。
///
/// 设计:构造函数注入 SharedPreferences + SecureStorage + onBaseUrlChange 回调,
/// 避免直接依赖 Riverpod ref(settingsProvider 由 provider 工厂注入回调)。
/// 这样 Notifier 本身可独立测试。
class SavedLoginsNotifier extends StateNotifier<SavedLoginsState> {
  final SharedPreferences _prefs;
  final SecureStorage _storage;
  final void Function(String baseUrl)? _onBaseUrlChange;
  // 切换账号状态机用:登录前登出当前账号、用保存的密码登录目标账号。
  // 回调注入避免循环依赖(savedLoginsProvider 不直接持有 authProvider 引用)。
  // onLogout 的 silent:true 表示切换中静默登出(保留 isSwitching,不触发 router 跳转)。
  final Future<void> Function({bool silent}) _onLogout;
  final Future<void> Function(String username, String password) _onLogin;
  // 切换进行中标记回调:通知 auth 置 isSwitching,让 router 视同已登录不乱跳。
  final void Function(bool switching) _onSwitchingChange;

  SavedLoginsNotifier({
    required SharedPreferences prefs,
    required SecureStorage storage,
    void Function(String baseUrl)? onBaseUrlChange,
    required Future<void> Function({bool silent}) onLogout,
    required Future<void> Function(String username, String password) onLogin,
    required void Function(bool switching) onSwitchingChange,
  })  : _prefs = prefs,
        _storage = storage,
        _onBaseUrlChange = onBaseUrlChange,
        _onLogout = onLogout,
        _onLogin = onLogin,
        _onSwitchingChange = onSwitchingChange,
        super(const SavedLoginsState());

  /// 启动时从 SharedPreferences 解密加载 + 恢复 selectedIndex。
  /// 解密失败(重装/换设备)清空数据,当作零记录处理。
  Future<void> load() async {
    final ciphertext = _prefs.getString(_kSavedLoginsKey);
    if (ciphertext == null) {
      state = const SavedLoginsState();
      return;
    }
    try {
      final plaintext = await _storage.decrypt(ciphertext);
      final list = (jsonDecode(plaintext) as List)
          .map((e) => SavedLogin.fromJson(e as Map<String, dynamic>))
          .toList();
      final index = _prefs.getInt(_kLastLoginIndexKey) ?? -1;
      // 防御:存的 index 可能因数据变化失效
      final safeIndex = (index >= 0 && index < list.length) ? index : -1;
      state = SavedLoginsState(logins: list, selectedIndex: safeIndex);
      if (safeIndex >= 0) {
        _onBaseUrlChange?.call(list[safeIndex].server);
      }
    } catch (_) {
      // 解密失败:清空,降级为零记录
      await _prefs.remove(_kSavedLoginsKey);
      await _prefs.remove(_kLastLoginIndexKey);
      state = const SavedLoginsState();
    }
  }

  /// 登录成功后调:存在同 server+username 则更新密码(+label/mark),否则新增;并选中。
  Future<void> saveOrAdd(
    String server,
    String username,
    String password, {
    String? label,
    AccountMark? mark,
  }) async {
    final idx = state.logins.indexWhere((l) => l.matches(server, username));
    if (idx >= 0) {
      final updated = List<SavedLogin>.from(state.logins);
      updated[idx] = updated[idx].copyWith(
        password: password,
        label: label ?? updated[idx].label,
        mark: mark ?? updated[idx].mark,
      );
      state = SavedLoginsState(logins: updated, selectedIndex: idx);
    } else {
      final updated = [
        ...state.logins,
        SavedLogin(
          server: server,
          username: username,
          password: password,
          label: label,
          mark: mark,
        ),
      ];
      state = SavedLoginsState(logins: updated, selectedIndex: updated.length - 1);
    }
    await _persist();
  }

  /// 选择账号页「+」按钮:新增并选中。重复则更新密码。
  Future<void> add(
    String server,
    String username,
    String password, {
    String? label,
    AccountMark? mark,
  }) =>
      saveOrAdd(server, username, password, label: label, mark: mark);

  /// 编辑指定索引。如果 server+username 跟其他卡片撞,抛 ArgumentError。
  ///
  /// label 哨兵语义:null=不改;""=清空为 null;非空=更新。
  /// mark 语义:null=不改(除非 clearMark=true → 清空为 null)。
  Future<void> edit(
    int index, {
    String? server,
    String? username,
    String? password,
    String? label,
    AccountMark? mark,
    bool clearMark = false,
  }) async {
    if (index < 0 || index >= state.logins.length) {
      throw RangeError('edit index 越界: $index');
    }
    final current = state.logins[index];
    final newServer = server ?? current.server;
    final newUsername = username ?? current.username;
    final newPassword = password ?? current.password;

    // 检查是否跟其他卡片撞(排除自己)
    final clash = state.logins.asMap().entries.where((e) => e.key != index).any(
          (e) => e.value.matches(newServer, newUsername),
        );
    if (clash) {
      throw ArgumentError('该组合已存在: $newUsername @ $newServer');
    }

    // label:null=不改;""=清空;其他=更新
    final newLabel = label == null
        ? current.label
        : (label.isEmpty ? null : label);
    // mark:null=不改(除非 clearMark → 清空)
    final newMark = clearMark ? null : (mark ?? current.mark);

    final updated = List<SavedLogin>.from(state.logins);
    updated[index] = SavedLogin(
      server: newServer,
      username: newUsername,
      password: newPassword,
      label: newLabel,
      mark: newMark,
    );
    state = SavedLoginsState(logins: updated, selectedIndex: state.selectedIndex);
    await _persist();
  }

  /// 删除指定索引。删的是选中项则 selectedIndex 回退 -1。
  /// 删非选中项且在选中项之前,selectedIndex 顺移 -1。
  Future<void> remove(int index) async {
    if (index < 0 || index >= state.logins.length) return;
    final updated = List<SavedLogin>.from(state.logins)..removeAt(index);
    int newIndex = state.selectedIndex;
    if (index == newIndex) {
      newIndex = -1;
    } else if (index < newIndex) {
      newIndex -= 1;
    }
    state = SavedLoginsState(logins: updated, selectedIndex: newIndex);
    await _persist();
  }

  /// 选中指定索引。同步触发 onBaseUrlChange(settingsProvider 同步)。
  void select(int index) {
    if (index < 0 || index >= state.logins.length) return;
    state = state.copyWith(selectedIndex: index);
    _onBaseUrlChange?.call(state.logins[index].server);
    _prefs.setInt(_kLastLoginIndexKey, index);
  }

  /// 一键静默切换到指定账号(登录前/登录后通用)。
  /// 编排:置 isSwitching → onLogout(silent,保留 isSwitching)→
  ///      select(同步新 baseUrl)→ onLogin(用保存密码登录新 server)→ 清 isSwitching。
  /// 同索引 no-op;越界抛 RangeError。
  /// onLogin 失败则回滚 selectedIndex 到切换前位置并重新抛出异常。
  ///
  /// isSwitching 标记让 router 在 logout→login 中间态视同已登录,避免误跳 /login
  /// 造成页面闪烁/重建。logout 用 silent 模式保留 isSwitching,全程不广播未登录态。
  Future<void> switchTo(int index) async {
    if (index < 0 || index >= state.logins.length) {
      throw RangeError('switchTo index 越界: $index');
    }
    final previousIndex = state.selectedIndex;
    if (index == previousIndex) return; // no-op

    _onSwitchingChange(true);
    try {
      // silent logout:保留 isSwitching,不触发 router 跳 /login
      await _onLogout(silent: true);
      select(index); // 更新 selectedIndex + setBaseUrl(新 server)
      final target = state.logins[index];
      await _onLogin(target.username, target.password);
      // 成功:state 已是登录态,UI 自然跳转;密码去重更新由 authProvider.login 处理
    } catch (e) {
      // 失败:回滚 selectedIndex 到切换前,并恢复 baseUrl 到切换前的 server
      state = state.copyWith(selectedIndex: previousIndex);
      if (previousIndex >= 0 && previousIndex < state.logins.length) {
        _onBaseUrlChange?.call(state.logins[previousIndex].server);
      }
      rethrow;
    } finally {
      _onSwitchingChange(false);
    }
  }

  /// 加密 + 持久化 logins + last_login_index。
  Future<void> _persist() async {
    final plaintext = jsonEncode(state.logins.map((l) => l.toJson()).toList());
    final ciphertext = await _storage.encrypt(plaintext);
    await _prefs.setString(_kSavedLoginsKey, ciphertext);
    if (state.selectedIndex >= 0) {
      await _prefs.setInt(_kLastLoginIndexKey, state.selectedIndex);
    } else {
      await _prefs.remove(_kLastLoginIndexKey);
    }
  }
}

/// SharedPreferences 实例 provider。
///
/// 必须在 main.dart 中通过 `sharedPrefsProvider.overrideWithValue(instance)`
/// 注入已 load 好的实例(SharedPreferences.getInstance() 是 async,provider 工厂不能 await)。
/// 测试环境用 SharedPreferences.setMockInitialValues + getInstance 构造后 override。
final sharedPrefsProvider = Provider<SharedPreferences>((ref) {
  throw StateError('SharedPreferences 未注入:请在 main 中 override sharedPrefsProvider');
});

final savedLoginsProvider =
    StateNotifierProvider<SavedLoginsNotifier, SavedLoginsState>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  final storage = SecureStorage();
  return SavedLoginsNotifier(
    prefs: prefs,
    storage: storage,
    onBaseUrlChange: (url) =>
        ref.read(settingsProvider.notifier).setBaseUrl(url),
    onLogout: ({bool silent = false}) =>
        ref.read(authProvider.notifier).logout(silent: silent),
    // 切换账号的 onLogin:login 前必须确保 authNotifier.api 已切到新 baseUrl。
    // select 触发的 settings 变化会让 apiProvider 失效,但它是 lazy Provider,
    // 且 ref.listen(apiProvider, setApi) 的回调在 microtask 中触发——若直接 await
    // authProvider.login(),login 内的 api.login() 仍打到旧 baseUrl(竞态)。
    // 这里在 login 前显式 invalidate + read 强制同步重建 apiProvider,并同步 setApi,
    // 彻底消除 microtask 时序依赖。
    onLogin: (username, password) async {
      ref.invalidate(apiProvider);
      final newApi = ref.read(apiProvider);
      ref.read(authProvider.notifier).setApi(newApi);
      await ref.read(authProvider.notifier).login(username, password);
    },
    onSwitchingChange: (switching) =>
        ref.read(authProvider.notifier).setSwitching(switching),
  );
});
