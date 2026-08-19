import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/friendship.dart';
import 'package:wanling_core/models/user_summary.dart';
import 'package:wanling_core/models/ws_message.dart';
import '../services/api_service.dart';
import '../services/local_message_store_abstract.dart';
import '../services/noop_local_message_store.dart';
import '../services/websocket_service.dart';
import 'package:wanling_core/utils/diff_merge.dart';
// 复用现有 provider，避免重复定义导致状态分裂。
import 'auth_provider.dart' show apiProvider, authProvider;
import 'chat_provider.dart' show wsProvider;
import 'local_message_store_provider.dart' show localMessageStoreProvider;

/// 好友系统聚合状态：好友列表 + 收到的 pending 请求 + 发出的 pending 请求。
///
/// 三列表都从 server 拉取，并通过 WebSocket 事件（FRIEND_REQUEST_RECEIVED /
/// DECIDED / REMOVED）做本地增量同步。当无法精确同步（如 DECIDED 不带 user
/// 摘要、REMOVED 不带 username）时，回退到 [load] 重拉。
class FriendListState {
  /// 已建立的好友关系（accepted）。
  final List<UserSummary> friends;

  /// 我收到的 pending 请求（我是接收方）。
  final List<FriendRequest> incoming;

  /// 我发出的 pending 请求（我是发起方）。
  final List<FriendRequest> outgoing;

  const FriendListState({
    this.friends = const [],
    this.incoming = const [],
    this.outgoing = const [],
  });

  /// 收到的请求数量。消息 tab 红点用。
  int get incomingCount => incoming.length;

  /// 总未读 = 收到的请求数（简化：每个 incoming 都是"未处理"）。
  int get totalUnread => incomingCount;

  /// 该 username 是否已是好友。
  bool isFriend(String username) =>
      friends.any((f) => f.username == username);

  /// 是否已向该 username 发出 pending 请求。
  bool hasOutgoing(String username) =>
      outgoing.any((r) => r.user.username == username);

  FriendListState copyWith({
    List<UserSummary>? friends,
    List<FriendRequest>? incoming,
    List<FriendRequest>? outgoing,
  }) =>
      FriendListState(
        friends: friends ?? this.friends,
        incoming: incoming ?? this.incoming,
        outgoing: outgoing ?? this.outgoing,
      );
}

/// 好友列表 + 请求全生命周期管理。
///
/// F5: cache-first load(三列表分别缓存 + diff-merge)+ WS 关键事件落库。
class FriendListNotifier extends StateNotifier<FriendListState> {
  final ApiService _api;
  final WebSocketService _ws;
  final LocalMessageStore _store; // F5 新增
  final String ownerId; // F5 新增
  StreamSubscription<WSMessage>? _sub;

  FriendListNotifier(
    this._api,
    this._ws, {
    required LocalMessageStore store,
    required this.ownerId,
    bool autoload = true,
  })  : _store = store,
        super(const FriendListState()) {
    if (autoload) {
      // 切换账号时 apiProvider/wsProvider 重建会连带重建本 notifier,
      // 新 server 的数据需重新拉。autoload=false 仅供单元测试跳过 load。
      load();
    }
    _sub = _ws.friendUpdates.listen(_onFriendEvent);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// F5: cache-first load 三列表分别缓存 + diff-merge + 落库。
  ///
  /// 流程:
  /// 1. await store.getFriends/getFriendRequests(incoming/outgoing) → state=cached
  /// 2. 后台 Future.wait([listFriends, listIncoming, listOutgoing])
  /// 3. 空三列表保护(都空 + 本地有数据 → 不覆盖)
  /// 4. 三列表分别 diff-merge(当前无 client-only 字段,直接用 fresh)
  /// 5. fire-and-forget 三列表分别落库
  Future<void> load() async {
    // F5: cache-first 三列表分别读
    List<UserSummary> cachedFriends;
    List<FriendRequest> cachedIncoming;
    List<FriendRequest> cachedOutgoing;
    try {
      cachedFriends = await _store.getFriends(ownerId);
      cachedIncoming = await _store.getFriendRequests(ownerId, 'incoming');
      cachedOutgoing = await _store.getFriendRequests(ownerId, 'outgoing');
    } catch (e) {
      debugPrint('[friend] store.getXxx fail: $e');
      cachedFriends = [];
      cachedIncoming = [];
      cachedOutgoing = [];
    }
    if (!mounted) return;
    if (cachedFriends.isNotEmpty ||
        cachedIncoming.isNotEmpty ||
        cachedOutgoing.isNotEmpty) {
      state = FriendListState(
        friends: cachedFriends,
        incoming: cachedIncoming,
        outgoing: cachedOutgoing,
      );
    }

    // 后台 API 刷新
    try {
      final results = await Future.wait<dynamic>([
        _api.listFriends(),
        _api.listIncomingFriendRequests(),
        _api.listOutgoingFriendRequests(),
      ]);
      if (!mounted) return;

      final freshFriends = results[0] as List<UserSummary>;
      final freshIncoming = results[1] as List<FriendRequest>;
      final freshOutgoing = results[2] as List<FriendRequest>;

      // 空三列表保护(server 异常返空时不清本地)
      if (freshFriends.isEmpty &&
          freshIncoming.isEmpty &&
          freshOutgoing.isEmpty &&
          (state.friends.isNotEmpty ||
              state.incoming.isNotEmpty ||
              state.outgoing.isNotEmpty)) {
        return;
      }

      // F5: 三列表分别 diff-merge, 当前无 client-only 字段, 直接用 fresh
      final mergedFriends = diffMerge(
        localList: state.friends,
        freshList: freshFriends,
        idOf: (f) => f.username,
        mergeItem: (local, f) => f,
        keepLocal: (_) => false,
      );
      final mergedIncoming = diffMerge(
        localList: state.incoming,
        freshList: freshIncoming,
        idOf: (r) => r.id,
        mergeItem: (local, f) => f,
        keepLocal: (_) => false,
      );
      final mergedOutgoing = diffMerge(
        localList: state.outgoing,
        freshList: freshOutgoing,
        idOf: (r) => r.id,
        mergeItem: (local, f) => f,
        keepLocal: (_) => false,
      );

      state = FriendListState(
        friends: mergedFriends,
        incoming: mergedIncoming,
        outgoing: mergedOutgoing,
      );

      // fire-and-forget 三列表分别落库
      _store.putFriends(ownerId, mergedFriends).catchError(
        (e) => debugPrint('[friend] store.putFriends fail: $e'),
      );
      _store
          .putFriendRequests(ownerId, 'incoming', mergedIncoming)
          .catchError(
        (e) =>
            debugPrint('[friend] store.putFriendRequests(incoming) fail: $e'),
      );
      _store
          .putFriendRequests(ownerId, 'outgoing', mergedOutgoing)
          .catchError(
        (e) =>
            debugPrint('[friend] store.putFriendRequests(outgoing) fail: $e'),
      );
    } catch (_) {
      // REST 失败保留旧 state, 避免列表闪烁(原 F4 行为保持)
    }
  }

  /// 发起好友请求（by username）。
  ///
  /// server 409（已是好友 / 已有 pending）→ 抛异常，UI 用 AppDialog/SnackBar 提示。
  /// 成功后将请求加到 outgoing（乐观本地）。
  Future<String> sendRequest(String toUsername) async {
    // API 已返 FriendRequest model(Task 15),内部已做 to_user → user 字段映射。
    final fr = await _api.createFriendRequest(toUsername);
    final requestId = fr.id;
    if (!mounted) return requestId;
    state = state.copyWith(outgoing: [...state.outgoing, fr]);

    // F5: outgoing 落库
    _store.putFriendRequests(ownerId, 'outgoing', state.outgoing).catchError(
      (e) =>
          debugPrint('[friend] store.putFriendRequests(outgoing) fail: $e'),
    );
    return requestId;
  }

  /// 接受好友请求（我是接收方）。
  ///
  /// 成功后将该请求从 incoming 移到 friends（本地乐观）。
  Future<void> accept(String requestId) async {
    await _api.acceptFriendRequest(requestId);
    if (!mounted) return;
    final idx = state.incoming.indexWhere((r) => r.id == requestId);
    if (idx == -1) return;
    final req = state.incoming[idx];
    state = state.copyWith(
      incoming: state.incoming.where((r) => r.id != requestId).toList(),
      friends: [...state.friends, req.user],
    );

    // F5: incoming + friends 落库
    _store.putFriendRequests(ownerId, 'incoming', state.incoming).catchError(
      (e) =>
          debugPrint('[friend] store.putFriendRequests(incoming) fail: $e'),
    );
    _store.putFriends(ownerId, state.friends).catchError(
      (e) => debugPrint('[friend] store.putFriends fail: $e'),
    );
  }

  /// 拒绝好友请求（我是接收方）。
  Future<void> reject(String requestId) async {
    await _api.rejectFriendRequest(requestId);
    if (!mounted) return;
    state = state.copyWith(
      incoming: state.incoming.where((r) => r.id != requestId).toList(),
    );

    // F5: incoming 落库
    _store.putFriendRequests(ownerId, 'incoming', state.incoming).catchError(
      (e) =>
          debugPrint('[friend] store.putFriendRequests(incoming) fail: $e'),
    );
  }

  /// 删除好友(任一方)。
  ///
  /// server 路由 `DELETE /api/users/me/friends/:username`(spec §4.2:client 不持
  /// user_id 防枚举,server 内部 username → user_id 反查)。
  Future<void> removeFriend(String username) async {
    // 先本地乐观移除(UI 立即响应)
    state = state.copyWith(
      friends: state.friends.where((f) => f.username != username).toList(),
    );
    await _api.removeFriend(username);

    // F5: friends 落库
    _store.putFriends(ownerId, state.friends).catchError(
      (e) => debugPrint('[friend] store.putFriends fail: $e'),
    );
  }

  /// WebSocket 好友事件处理 + F5 落库。
  void _onFriendEvent(WSMessage m) {
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;

    switch (m.t) {
      case 'FRIEND_REQUEST_RECEIVED':
        _onRequestReceived(data);
        break;
      case 'FRIEND_REQUEST_DECIDED':
        _onRequestDecided(data);
        break;
      case 'FRIEND_REMOVED':
        // payload: {by_user, friend_id}。无法精确知道是哪个好友(client 无 user_id),
        // 直接 reload 拉最新 friends 列表(reload 内部已落库)。
        load();
        break;
    }
  }

  void _onRequestReceived(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    // server payload 用 from_user_summary（spec §5.2）。兼容老形态 from_user。
    final rawFrom = data['from_user_summary'] ?? data['from_user'];
    if (rawFrom is! Map<String, dynamic>) return;
    final fromUser = UserSummary.fromJson(rawFrom);
    final createdAtStr = data['created_at'] as String?;
    final createdAt =
        createdAtStr != null ? DateTime.parse(createdAtStr) : DateTime.now();
    // 去重：同 request_id 已存在不重复加（WS 重连补发场景）
    if (state.incoming.any((r) => r.id == requestId)) return;
    final newReq = FriendRequest(
      id: requestId,
      status: FriendshipStatus.pending,
      createdAt: createdAt,
      user: fromUser,
    );
    state = state.copyWith(incoming: [newReq, ...state.incoming]);

    // F5: incoming 落库
    _store.putFriendRequests(ownerId, 'incoming', state.incoming).catchError(
      (e) =>
          debugPrint('[friend] store.putFriendRequests(incoming) fail: $e'),
    );
  }

  void _onRequestDecided(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final decision = data['decision'] as String?; // accepted / rejected / canceled
    // outgoing 移除该 request（无论 decision）
    state = state.copyWith(
      outgoing: state.outgoing.where((r) => r.id != requestId).toList(),
    );
    // accepted 时本地 friends 列表需要 +1,但 DECIDED payload 不带 user 摘要,
    // 直接 reload 拉最新。
    if (decision == 'accepted') {
      load(); // reload 内部已落库,这里不再重复
      return;
    }

    // F5: outgoing 落库(非 accepted 路径)
    _store.putFriendRequests(ownerId, 'outgoing', state.outgoing).catchError(
      (e) =>
          debugPrint('[friend] store.putFriendRequests(outgoing) fail: $e'),
    );
  }
}

final friendListProvider =
    StateNotifierProvider<FriendListNotifier, FriendListState>((ref) {
  // F5: 从 FutureProvider 取 store,加载中或失败时用 NoopLocalMessageStore 降级
  final store = ref.watch(
      localMessageStoreProvider.select((async) => async.valueOrNull));
  final ownerId = ref.watch(authProvider.select((s) => s.user?.id ?? ''));
  return FriendListNotifier(
    ref.watch(apiProvider),
    ref.watch(wsProvider),
    store: store ?? NoopLocalMessageStore(),
    ownerId: ownerId,
  );
});

/// 收到请求数（消息 tab 红点用）。单独 provider 避免重建整 HomePage 子树。
final friendIncomingCountProvider = Provider<int>((ref) {
  return ref.watch(friendListProvider.select((s) => s.incomingCount));
});
