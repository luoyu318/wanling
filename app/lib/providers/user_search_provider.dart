import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/user_summary.dart';
import '../services/api_service.dart';
import 'auth_provider.dart' show apiProvider;

/// 用户搜索状态。
class UserSearchState {
  /// 当前搜索关键词。
  final String query;

  /// 搜索结果列表。
  final List<UserSummary> results;

  /// 是否正在请求 server。
  final bool loading;

  const UserSearchState({
    this.query = '',
    this.results = const [],
    this.loading = false,
  });

  UserSearchState copyWith({
    String? query,
    List<UserSummary>? results,
    bool? loading,
  }) =>
      UserSearchState(
        query: query ?? this.query,
        results: results ?? this.results,
        loading: loading ?? this.loading,
      );
}

/// username 模糊搜索 Notifier（500ms 防抖）。
///
/// 用户在 AddFriendPage 输入框输入 username 时调用 [updateQuery]：
///   - 空 query 立即清空 results（不调 server）
///   - 非空 query 标记 loading=true，500ms 后调 server
///   - 500ms 内再输入则取消上一次 timer（防抖）
///
/// 错误处理：try-catch 吞异常仅置 loading=false，UI 不弹错（Task 4.2 加提示）。
class UserSearchNotifier extends StateNotifier<UserSearchState> {
  final ApiService _api;
  Timer? _debounce;

  UserSearchNotifier(this._api) : super(const UserSearchState());

  /// 更新搜索关键词（500ms 防抖）。
  void updateQuery(String query) {
    state = state.copyWith(query: query);
    _debounce?.cancel();
    if (query.isEmpty) {
      // 空 query 立即清空结果，不发请求
      state = state.copyWith(results: [], loading: false);
      return;
    }
    state = state.copyWith(loading: true);
    _debounce = Timer(const Duration(milliseconds: 500), _search);
  }

  Future<void> _search() async {
    final query = state.query;
    try {
      final raw = await _api.searchUsers(query);
      if (!mounted) return;
      // 防抖兜底：若返回前 query 已变（用户继续输入触发新 timer），
      // 不写旧结果。timer 已被新 updateQuery 取消，这里 query 一致才写。
      if (state.query != query) return;
      final results = raw
          .map((e) => UserSummary.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(results: results, loading: false);
    } catch (_) {
      if (!mounted) return;
      state = state.copyWith(loading: false);
    }
  }

  /// 测试用：立即触发搜索（跳过 500ms 防抖）。
  @visibleForTesting
  Future<void> testFlush() => _search();

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final userSearchProvider =
    StateNotifierProvider<UserSearchNotifier, UserSearchState>((ref) {
  return UserSearchNotifier(ref.watch(apiProvider));
});
