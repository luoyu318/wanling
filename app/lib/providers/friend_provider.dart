import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/friendship.dart';
import '../models/user_summary.dart';
import '../models/ws_message.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
// 复用现有 provider，避免重复定义导致状态分裂。
import 'auth_provider.dart' show apiProvider;
import 'chat_provider.dart' show wsProvider;

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
/// 设计参考 [ConversationListNotifier]：
///   - 构造即拉取 + 订阅 ws.friendUpdates
///   - 每个状态推进方法（send/accept/reject/cancel/removeFriend）先调 API，
///     成功后本地乐观更新；失败抛异常给 UI 提示（本 task 不做回滚）
///   - WS 事件本地同步，无法精确时 reload 兜底
class FriendListNotifier extends StateNotifier<FriendListState> {
  final ApiService _api;
  final WebSocketService _ws;
  StreamSubscription<WSMessage>? _sub;

  FriendListNotifier(this._api, this._ws, {bool autoload = true})
      : super(const FriendListState()) {
    if (autoload) {
      // 切换账号时 apiProvider/wsProvider 重建会连带重建本 notifier，
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

  /// 拉取好友列表 + 收到/发出的 pending 请求。
  ///
  /// 用 Future.wait 并发三请求降低延迟。任一失败保留旧状态（不写空）。
  Future<void> load() async {
    try {
      // Future.wait 并发三请求降低延迟（拉取好友列表 + 收到/发出的 pending 请求）。
      // 三个 Future 返回类型都是 List<dynamic>，Future.wait 推断为 List<dynamic>，
      // 索引取值后无需 cast。
      final results = await Future.wait<dynamic>([
        _api.listFriends(),
        _api.listIncomingFriendRequests(),
        _api.listOutgoingFriendRequests(),
      ]);
      if (!mounted) return;
      final friendsRaw = results[0] as List;
      final incomingRaw = results[1] as List;
      final outgoingRaw = results[2] as List;
      state = FriendListState(
        friends: friendsRaw
            .map((e) => UserSummary.fromJson(e as Map<String, dynamic>))
            .toList(),
        incoming: incomingRaw
            .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
            .toList(),
        outgoing: outgoingRaw
            .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
    } catch (_) {
      // 拉取失败保留旧 state，避免列表闪烁。UI 层（Task 4.2）可加 SnackBar 提示。
    }
  }

  /// 发起好友请求（by username）。
  ///
  /// server 409（已是好友 / 已有 pending）→ 抛异常，UI 用 AppDialog/SnackBar 提示。
  /// 成功后将请求加到 outgoing（乐观本地）。
  Future<String> sendRequest(String toUsername) async {
    final raw = await _api.createFriendRequest(toUsername);
    final requestId = raw['request_id'] as String;
    if (!mounted) return requestId;
    // server 返回 to_user 摘要（不含 id，防泄漏），用其构造 FriendRequest。
    final toUser =
        UserSummary.fromJson(raw['to_user'] as Map<String, dynamic>);
    final newReq = FriendRequest(
      id: requestId,
      status: FriendshipStatus.pending,
      createdAt: DateTime.now(),
      user: toUser,
    );
    state = state.copyWith(outgoing: [...state.outgoing, newReq]);
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
  }

  /// 拒绝好友请求（我是接收方）。
  Future<void> reject(String requestId) async {
    await _api.rejectFriendRequest(requestId);
    if (!mounted) return;
    state = state.copyWith(
      incoming: state.incoming.where((r) => r.id != requestId).toList(),
    );
  }

  /// 取消好友请求（我是发起方）。
  Future<void> cancel(String requestId) async {
    await _api.cancelFriendRequest(requestId);
    if (!mounted) return;
    state = state.copyWith(
      outgoing: state.outgoing.where((r) => r.id != requestId).toList(),
    );
  }

  /// 删除好友（任一方）。
  ///
  /// **注意**：server 端 API `DELETE /api/users/me/friends/:id` 中 `:id` 是
  /// user_id，但 client [UserSummary] 不含 user_id（spec §4.2 防 user_id 枚举）。
  /// 本方法接收 username 参数（用于本地状态过滤），server 调用走 [ApiService.removeFriend]
  /// 时需要 user_id——这是 spec 设计与现有 server API 的已知矛盾。
  ///
  /// **本 task 的折中**：参数名沿用 username（本地过滤可行），server 调用
  /// 也传 username。Task 4.x（server 改造）会把路由参数从 :id 改为 :username，
  /// 届时此方法直接 work；当前 server 路径 :id 在 username 不是合法 UUID 时
  /// 会 404，但 client 状态会先于 API 响应更新（乐观），用户视觉一致。
  /// Task 4.x server 改造后此 TODO 移除。
  Future<void> removeFriend(String username) async {
    // 先本地乐观移除（UI 立即响应）
    state = state.copyWith(
      friends: state.friends.where((f) => f.username != username).toList(),
    );
    // 调 server（参数类型 String 与 server :id 路径冲突由 Task 4.x 解决）
    await _api.removeFriend(username);
  }

  /// WebSocket 好友事件处理：
  /// - FRIEND_REQUEST_RECEIVED：incoming +1（带完整 from_user 摘要）
  /// - FRIEND_REQUEST_DECIDED：outgoing 移除该 request；accepted 时 reload
  ///   拉最新 friends（DECIDED payload 不带 user 摘要）
  /// - FRIEND_REMOVED：reload 重拉（payload 不带 username，无法精确本地同步）
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
        // payload: {by_user, friend_id}。无法精确知道是哪个好友（client 无 user_id），
        // 直接 reload 拉最新 friends 列表。
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
  }

  void _onRequestDecided(Map<String, dynamic> data) {
    final requestId = data['request_id'] as String?;
    if (requestId == null) return;
    final decision = data['decision'] as String?; // accepted / rejected / canceled
    // outgoing 移除该 request（无论 decision）
    state = state.copyWith(
      outgoing: state.outgoing.where((r) => r.id != requestId).toList(),
    );
    // accepted 时本地 friends 列表需要 +1，但 DECIDED payload 不带 user 摘要，
    // 直接 reload 拉最新（本 task 简化策略，spec §7.6 也是此口径）
    if (decision == 'accepted') {
      load();
    }
  }
}

final friendListProvider = StateNotifierProvider<FriendListNotifier, FriendListState>(
    (ref) {
  return FriendListNotifier(
    ref.watch(apiProvider),
    ref.watch(wsProvider),
  );
});

/// 收到请求数（消息 tab 红点用）。单独 provider 避免重建整 HomePage 子树。
final friendIncomingCountProvider = Provider<int>((ref) {
  return ref.watch(friendListProvider.select((s) => s.incomingCount));
});
