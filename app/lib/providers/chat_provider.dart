import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/message.dart';
import '../models/msg_type.dart';
import '../models/unread_info.dart';
import '../models/ws_message.dart';
import '../rendering/card_renderer.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import 'auth_provider.dart';
import 'chat_state.dart';
import 'settings_provider.dart';

class ChatNotifier extends StateNotifier<ChatState> {
  final ApiService api;
  final WebSocketService ws;
  final String conversationId;
  final String? agentId;
  /// 当前 user.id，用于乐观更新消息的 senderId（user-user 会话按 senderId 区分自己/对方，
  /// 空字符串占位会导致消息显示在对方侧，见 chat_page.dart isMe 判断）。
  final String currentUserId;
  StreamSubscription<WSMessage>? _subscription;
  StreamSubscription<WSMessage>? _updateSubscription;

  static const int _pageSize = 100;

  ChatNotifier(this.api, this.ws, this.conversationId, this.agentId, this.currentUserId)
      : super(const ChatState()) {
    CardContentRenderer.onDecide = (approvalId, actionId, reason) {
      return api.decideApproval(approvalId, actionId, reason: reason);
    };
    _initialize();
    _listenWS();
    _listenUpdates();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _updateSubscription?.cancel();
    super.dispose();
  }

  /// 初始化：获取未读信息 → 拉首屏消息 → 定位。
  ///
  /// 有未读时用 firstUnreadCreatedAt 直接作 before 游标（不再用 _findMessageById
  /// 拉 N 条找 id，那个方案在未读 > N 时会失效）。
  /// 拉取结果用 _mergeHistory 合并，保留初始化期间 WS 并发到达的新消息
  /// （沿用现有防并发设计，避免直接覆盖丢失数据）。
  Future<void> _initialize() async {
    debugPrint('[chatInit] START convId=$conversationId');
    try {
      final unreadJson = await api.getUnreadInfo(conversationId);
      debugPrint('[chatInit] getUnreadInfo raw=$unreadJson');
      final unread = UnreadInfo.fromJson(unreadJson);
      debugPrint('[chatInit] unread parsed: count=${unread.unreadCount}, '
          'firstUnreadId=${unread.firstUnreadMessageId}, '
          'firstUnreadCreatedAt=${unread.firstUnreadCreatedAt}, '
          'hasMoreBeforeFirstUnread=${unread.hasMoreBeforeFirstUnread}');

      if (unread.unreadCount == 0) {
        // 无未读：拉最新 20 条
        debugPrint('[chatInit] BRANCH: no unread');
        final raw = await api.getMessagesBefore(conversationId, limit: _pageSize);
        final loaded = _parseMessages(raw);
        debugPrint('[chatInit] noUnread loaded ${loaded.length} msgs');
        state = _mergeHistory(loaded).copyWith(
          hasMore: loaded.length == _pageSize,
          unreadCount: 0,
          isInitialLoading: false,
        );
        debugPrint('[chatInit] noUnread state set: hasMore=${state.hasMore}, '
            'messages=${state.messages.length}');
      } else {
        // 有未读：用 firstUnreadCreatedAt 作 after 游标的起点（减 1ms 让 firstUnread
        // 本身也被 created_at > after 包含）。ListAfter 返回 ASC（最老在前），
        // reverse 后变 newest first（firstUnread 在末尾=视觉顶部，跳到它，下方是更新的未读）。
        // 这与"用户期望跳到第一条未读 + 上下文（前后消息）"一致。
        debugPrint('[chatInit] BRANCH: has unread');
        assert(unread.firstUnreadCreatedAt != null,
            'unreadCount > 0 但 firstUnreadCreatedAt 为 null，服务端数据不一致');
        final after = unread.firstUnreadCreatedAt!.subtract(
          const Duration(milliseconds: 1),
        );
        debugPrint('[chatInit] after cursor=$after');
        final raw = await api.getMessagesAfter(
          conversationId,
          after: after,
          limit: _pageSize,
        );
        debugPrint('[chatInit] getMessagesAfter returned ${raw.length} msgs');
        // ListAfter 返回 ASC，reverse 成 newest first 配合 reverse ListView
        final loaded = _parseMessages(raw).reversed.toList();
        if (loaded.isEmpty) {
          debugPrint('[chatInit] WARNING: loaded is empty after reverse!');
        } else {
          debugPrint('[chatInit] loaded after reverse: length=${loaded.length}, '
              'first(=最新, messages[0])=${loaded.first.id} createdAt=${loaded.first.createdAt}, '
              'last(=最老, firstUnread expected)=${loaded.last.id} createdAt=${loaded.last.createdAt}');
        }
        // hasMore 必须综合判断：
        // - ListAfter 取到 _pageSize 条 → 之后可能还有更新的消息
        // - 服务端告知 firstUnread 之前有已读历史 → 之前还有更老的消息（上滑加载）
        // 二者之一为真就允许上滑加载历史。
        // 修复 Bug B：原来只看 loaded.length == _pageSize，导致 ListAfter
        // 取不满时（如总共只有 10 条未读）误判 hasMore=false，永远拉不到
        // firstUnread 之前的已读历史。
        final hasMore = loaded.length == _pageSize ||
            unread.hasMoreBeforeFirstUnread;
        state = _mergeHistory(loaded).copyWith(
          hasMore: hasMore,
          unreadCount: unread.unreadCount,
          firstUnreadMessageId: unread.firstUnreadMessageId,
          showUnreadSeparator: true,
          isInitialLoading: false,
        );
        debugPrint('[chatInit] hasUnread state set: hasMore=$hasMore, '
            'firstUnreadMessageId=${state.firstUnreadMessageId}, '
            'unreadCount=${state.unreadCount}, '
            'messages.length=${state.messages.length}, '
            'messages.last(=最老,应等于firstUnread)=${state.messages.isEmpty ? null : state.messages.last.id}');
      }
    } catch (e, st) {
      debugPrint('[chatInit] EXCEPTION: $e\n$st');
      // 兜底：拉最新消息（定位/高亮全部放弃，保证列表可用）
      final raw = await api.getMessages(conversationId, limit: _pageSize, offset: 0);
      final loaded = _parseMessages(raw);
      state = _mergeHistory(loaded).copyWith(
        hasMore: loaded.length == _pageSize,
        isInitialLoading: false,
      );
      debugPrint('[chatInit] fallback state set: hasMore=${state.hasMore}, '
          'messages=${state.messages.length}');
    }
  }

  // API 返回 newest first，保持此顺序配合 ListView(reverse: true)
  List<ChatMessage> _parseMessages(List msgs) {
    return msgs.map((e) => ChatMessage.fromJson(e)).toList();
  }

  /// 把网络加载的消息合并进 state。保留 state 中并发 WS 到达、但网络结果
  /// 中未包含的新消息（如 _initialize 的 API 调用期间 WS 新增的消息），
  /// 避免直接覆盖丢失数据。
  ///
  /// **按 createdAt 降序排序**（newest first）消除对 extra/loaded 新旧关系的
  /// 假设：_initialize 场景下 extra 是 WS 推送的更新消息（[extra, loaded] 正确），
  /// 但 jumpToBottom 场景下 extra 是较老的历史（顺序反了，最老历史会被推到
  /// messages[0] = 视觉底部，表现为「历史压在最新消息下方」）。排序后两种场景
  /// 都正确，O(n log n) 成本可接受（n ≤ 几百）。
  ChatState _mergeHistory(List<ChatMessage> loaded) {
    final loadedIds = loaded.map((m) => m.id).toSet();
    final extra = state.messages.where((m) => !loadedIds.contains(m.id)).toList();
    final merged = [...extra, ...loaded];
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt)); // newest first
    return state.copyWith(messages: merged);
  }

  /// 用户主动滑到底部时标记已读：清未读计数 + 分割线 + firstUnread，
  /// 调 markConversationRead 同步服务端。**不重拉数据**（用户已在底部，
  /// state.messages 已包含最新消息，无需 jumpToBottom 那种「丢弃历史上下文」）。
  ///
  /// 与 [jumpToBottom] 的区别：
  /// - jumpToBottom：点击浮标用，hasMore=true 时重拉最新一页丢弃历史上下文
  /// - markReadAtBottom：用户滑到底部用，保留当前 state 只清状态
  Future<void> markReadAtBottom() async {
    if (state.unreadCount == 0 &&
        !state.showUnreadSeparator &&
        state.firstUnreadMessageId == null) {
      return; // 已是清白状态，无需重复操作
    }
    state = state.copyWith(
      unreadCount: 0,
      showUnreadSeparator: false,
      clearFirstUnread: true,
    );
    try {
      await api.markConversationRead(conversationId);
    } catch (_) {}
  }

  /// 上滑加载更早的历史消息。
  /// 调用方需在调用前调 ChatScrollObserver.standby() 保持位置。
  Future<void> loadMoreHistory() async {
    debugPrint('[loadMore] CALLED: isLoadingMore=${state.isLoadingMore}, '
        'hasMore=${state.hasMore}, messages.length=${state.messages.length}');
    if (state.isLoadingMore || !state.hasMore || state.messages.isEmpty) {
      debugPrint('[loadMore] ABORT: guard failed');
      return;
    }

    state = state.copyWith(isLoadingMore: true);

    final oldest = state.messages.last; // newest first，last = 最老
    debugPrint('[loadMore] oldest.id=${oldest.id}, oldest.createdAt=${oldest.createdAt}');
    try {
      final raw = await api.getMessagesBefore(
        conversationId,
        before: oldest.createdAt,
        limit: _pageSize,
      );
      final older = _parseMessages(raw);
      debugPrint('[loadMore] fetched ${older.length} older msgs');
      state = state.copyWith(
        messages: [...state.messages, ...older], // 追加到末尾（更老的消息）
        hasMore: older.length == _pageSize,
        isLoadingMore: false,
      );
      debugPrint('[loadMore] DONE: new hasMore=${state.hasMore}, '
          'messages.length=${state.messages.length}');
    } catch (e, st) {
      debugPrint('[loadMore] EXCEPTION: $e\n$st');
      state = state.copyWith(isLoadingMore: false);
    }
  }

  /// 跳到最新消息（点击浮标时调用）。
  ///
  /// hasMore=true（消息不连续）时重新拉最新一页，丢弃已加载的历史上下文。
  /// 注意：本方法只更新 state，**实际滚动由 ChatPage 调 standby() + animateTo 完成**
  /// （state 变化驱动 build 重建，standby 保证位置不跳）。
  Future<void> jumpToBottom() async {
    if (state.hasMore) {
      final raw = await api.getMessagesBefore(conversationId, limit: _pageSize);
      final loaded = _parseMessages(raw);
      state = _mergeHistory(loaded).copyWith(
        hasMore: loaded.length == _pageSize,
        unreadCount: 0,
        showUnreadSeparator: false,
        clearFirstUnread: true,
      );
    } else {
      state = state.copyWith(
        unreadCount: 0,
        showUnreadSeparator: false,
        clearFirstUnread: true,
      );
    }

    // 标记已读（best effort，失败不影响 UI）
    try {
      await api.markConversationRead(conversationId);
    } catch (_) {}
  }

  /// 会话内收到 agent 消息且用户不在底部时累加未读计数（未读浮标）。
  /// 由 ChatPage.ref.listen 在 _isAtBottom == false 时调用。
  void incrementUnread() {
    state = state.copyWith(unreadCount: state.unreadCount + 1);
  }

  /// 用户上滑阅读未读消息时，按「已进入视口的未读条数」批量减少未读计数。
  /// 由 ChatPage._checkUnreadSeen 检测视口内未读消息后调用。
  ///
  /// 当 unreadCount 减到 0 时同时清 firstUnreadMessageId + showUnreadSeparator，
  /// 与 markReadAtBottom / jumpToBottom 对未读字段的清白口径一致。
  void decrementUnread(int n) {
    if (n <= 0) {
      debugPrint('[decrement] SKIP: n=$n (no-op)');
      return;
    }
    final oldCount = state.unreadCount;
    final newCount = oldCount - n;
    if (newCount <= 0) {
      state = state.copyWith(
        unreadCount: 0,
        clearFirstUnread: true,
        showUnreadSeparator: false,
      );
    } else {
      state = state.copyWith(unreadCount: newCount);
    }
    debugPrint('[decrement] $oldCount - $n = ${state.unreadCount}'
        '${newCount <= 0 ? " (clamp+clear)" : ""}');
  }

  /// 收到新 WS 消息：仅头部插入 + 去重。
  ///
  /// **不改计数**：是否在底部（_isAtBottom）是 UI 层状态，Notifier 无法得知。
  /// 计数由 ChatPage.ref.listen 监测到 messages 增长后，根据 _isAtBottom 调
  /// incrementUnread 完成（见 ChatPage build）。
  void _onMessageCreate(Map<String, dynamic> msgData) {
    if (msgData['conversation_id'] != conversationId) return;
    final msg = ChatMessage.fromJson(msgData);
    if (state.messages.any((c) => c.id == msg.id)) return; // 去重
    state = state.copyWith(messages: [msg, ...state.messages]);
  }

  void _listenWS() {
    _subscription = ws.messages
        .where((m) => m.t == 'MESSAGE_CREATE' || m.t == 'MESSAGE_DELETE')
        .listen((m) {
      if (m.t == 'MESSAGE_DELETE') {
        final msgData = m.d as Map<String, dynamic>;
        if (msgData['conversation_id'] != conversationId) return;
        final ids = (msgData['ids'] as List).cast<String>().toSet();
        final scope = (msgData['scope'] as String?) ?? 'hide';
        if (scope == 'recall') {
          // 撤回:保留消息 id 切 recalled 态(占位提示),不发自己撤回的(已乐观切过)。
          // payload 含 sender_name,供群聊场景显示「${name} 撤回了一条消息」。
          // dm 场景 client 用 m.senderId == currentUserId 判断「你/对方」。
          final senderName = msgData['sender_name'] as String? ?? '';
          state = state.copyWith(
            messages: state.messages
                .map((m) => ids.contains(m.id) && !m.isRecalled
                    ? m.copyWith(isRecalled: true, recalledByName: senderName)
                    : m)
                .toList(),
          );
        } else {
          // hide:直接移除(只对我消失)
          state = state.copyWith(
            messages: state.messages.where((msg) => !ids.contains(msg.id)).toList(),
          );
        }
        return;
      }
      _onMessageCreate(m.d as Map<String, dynamic>);
    });
  }

  void _listenUpdates() {
    _updateSubscription = ws.messageUpdates.listen((msg) {
      final payload = msg.d as Map<String, dynamic>?;
      if (payload == null) return;
      if (payload['conversation_id'] != conversationId) return;

      final msgId = payload['message_id'] as String?;
      if (msgId == null) return;

      final idx = state.messages.indexWhere((m) => m.id == msgId);
      if (idx < 0) return;

      final newContent = payload['content'] as Map<String, dynamic>?;
      if (newContent == null) return;

      final updated = state.messages[idx].copyWith(content: newContent);
      final newList = List.of(state.messages);
      newList[idx] = updated;
      state = state.copyWith(messages: newList);
    });
  }

  Future<void> sendText(String text) async {
    final content = {
      'msg_type': MsgType.text.value,
      'data': {'text': text},
    };
    final localId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    _appendOptimisticMessage(content: content, localId: localId);
    try {
      final result = await api.sendMessage(conversationId, content);
      _replaceLocalWithServerId(
        localId,
        serverId: result.messageId,
        serverCreatedAt: result.createdAt,
      );
    } catch (e) {
      _markFailed(localId);
    }
  }

  Future<void> sendFile(String fileId, MsgType msgType) async {
    final content = {
      'msg_type': msgType.value,
      'data': {'file_id': fileId},
    };
    final localId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    _appendOptimisticMessage(content: content, localId: localId);
    try {
      final result = await api.sendMessage(conversationId, content);
      _replaceLocalWithServerId(
        localId,
        serverId: result.messageId,
        serverCreatedAt: result.createdAt,
      );
    } catch (e) {
      _markFailed(localId);
    }
  }

  /// 重试失败的发送消息。点击失败气泡的重试按钮时调。
  ///
  /// 流程:找失败消息 → 切回 sending → 调 api.sendMessage →
  /// 成功替换 id + 切 sent;失败再切 failed。
  Future<void> retrySend(String failedLocalId) async {
    final idx = state.messages.indexWhere((m) => m.id == failedLocalId);
    if (idx < 0) return;
    final msg = state.messages[idx];
    if (msg.status != MessageStatus.failed) return;

    // 切回 sending
    state = state.copyWith(
      messages: state.messages
          .map((m) =>
              m.id == failedLocalId ? m.copyWith(status: MessageStatus.sending) : m)
          .toList(),
    );

    try {
      final result = await api.sendMessage(conversationId, msg.content);
      _replaceLocalWithServerId(
        failedLocalId,
        serverId: result.messageId,
        serverCreatedAt: result.createdAt,
      );
    } catch (e) {
      _markFailed(failedLocalId);
    }
  }

  /// 删除本地失败消息(不调 server)。失败重试菜单的「删除」用。
  void removeLocalMessage(String localId) {
    state = state.copyWith(
      messages: state.messages.where((m) => m.id != localId).toList(),
    );
  }

  /// 发送方乐观更新：本地立即插入一条临时消息让 UI 即时显示。
  ///
  /// **id 用 local_ 前缀**：避免跟 server 生成的 UUID 冲突。HTTP 成功后调
  /// _replaceLocalWithServerId 替换为 server 真值。
  /// **sender_id 用真实 currentUserId**：isMe 判断走 senderId == currentUserId,
  /// 必须用真实 id 才能让乐观消息显示在右侧(自己侧)。
  /// **status=sending**:气泡外侧显示 loading,server 返回后切 sent 或 failed。
  void _appendOptimisticMessage({
    required Map<String, dynamic> content,
    required String localId,
  }) {
    final tempMsg = ChatMessage(
      id: localId,
      conversationId: conversationId,
      senderType: 'user',
      senderId: currentUserId,
      content: content,
      isRead: true,
      createdAt: DateTime.now(),
      status: MessageStatus.sending,
    );
    state = state.copyWith(messages: [tempMsg, ...state.messages]);
  }

  /// HTTP 发送成功后,把本地 local_xxx id 替换为 server 真值。
  /// 同步切 status=sent,server echo 后续到达时按 server id 去重(命中现有 _onMessageCreate)。
  void _replaceLocalWithServerId(
    String localId, {
    required String serverId,
    required DateTime serverCreatedAt,
  }) {
    state = state.copyWith(
      messages: state.messages
          .map((m) => m.id == localId
              ? m.copyWith(
                  id: serverId,
                  createdAt: serverCreatedAt,
                  status: MessageStatus.sent,
                )
              : m)
          .toList(),
    );
  }

  /// HTTP 发送失败,切 status=failed。气泡外侧重试按钮。
  void _markFailed(String localId) {
    state = state.copyWith(
      messages: state.messages
          .map((m) =>
              m.id == localId ? m.copyWith(status: MessageStatus.failed) : m)
          .toList(),
    );
  }

  /// 删除/撤回消息。
  /// scope='hide' (默认):对自己隐藏,乐观本地移除。
  /// scope='recall':撤回,乐观本地切 recalled 态(占位提示),server 确认后广播切全员。
  Future<void> deleteMessages(List<String> ids, {String scope = 'hide'}) async {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    if (scope == 'recall') {
      // 撤回:乐观本地切 recalled 态(保留消息 id,UI 显示占位)。
      // 单条操作(ids.length == 1),取首条作为 recalled 占位。
      state = state.copyWith(
        messages: state.messages
            .map((m) => idSet.contains(m.id)
                ? m.copyWith(isRecalled: true, recalledByName: '')
                : m)
            .toList(),
      );
    } else {
      // hide:乐观本地移除
      state = state.copyWith(
        messages: state.messages.where((m) => !idSet.contains(m.id)).toList(),
      );
    }
    try {
      if (ids.length == 1) {
        await api.deleteMessage(ids.first, scope: scope);
      } else {
        await api.batchDeleteMessages(ids);
      }
    } catch (e) {
      await _initialize();
      rethrow;
    }
  }
}

final wsProvider = Provider<WebSocketService>((ref) {
  // 只订阅 token 字段：updateProfile 等会刷新 state.user，若 watch 整个 AuthState
  // 会触发 WS 重建并断连。token 不变时 WS 保持连接。
  final token = ref.watch(authProvider.select((s) => s.token));
  final baseUrl = ref.watch(settingsProvider);
  final ws = WebSocketService();
  ref.onDispose(() => ws.disconnect());
  if (token != null) {
    ws.configure(baseUrl: baseUrl, token: token);
    ws.connect();
  }
  return ws;
});

/// WS 连接状态流 provider。banner 通过它订阅连接状态。
///
/// 依赖 wsProvider：切换账号时 token 变化触发 wsProvider 重建，本 provider 一并
/// 重建并订阅新实例的状态流。若 banner 直接 ref.read(wsProvider) 只订阅一次，
/// 切换后会监听已被 dispose 的旧实例，旧 stream 不再发 connected 事件，
/// banner 会永远卡在「已断开」。用 StreamProvider 桥接让订阅跟随实例切换。
final connStateProvider = StreamProvider<ConnState>((ref) {
  final ws = ref.watch(wsProvider);
  // 先同步推一次当前状态，避免订阅期间（connected 的实例没新事件时）banner
  // 误判为断开。StreamController 广播流不支持 sync 投递，用一个合并流。
  return Stream.multi((controller) {
    controller.add(ws.currentConnState);
    final sub = ws.connectionStateStream.listen(controller.add);
    sub.onDone(controller.close);
  });
});

/// family key 用 record：convId 决定历史拉取 + WS 发送目标（按 conv_id 路由），
/// agentId 仅用于 ChatPage 显示 agent 信息（typing / AppBar / 在线状态），
/// 可空（user-user DM 会话无 agent）。两者共同唯一确定一个聊天上下文。
///
/// **autoDispose**：ChatPage 退出即 dispose，重入重新 _initialize。
/// 修复 messages 累积 bug：原 family（非 autoDispose）缓存 state，重入不
/// 重新加载，WS 推送的新消息让 messages 持续累积（80→90→...），firstUnread
/// 在 messages 中的 index 漂移，scrollview_observer.jumpTo 在大列表上失效。
/// autoDispose 保证每次进入会话 state 都是全新的，firstUnread 始终是
/// messages.last（视觉顶部），jumpTo 容易精确跳转。
final chatProvider = StateNotifierProvider.autoDispose.family<ChatNotifier, ChatState,
    ({String convId, String? agentId})>((ref, key) {
  return ChatNotifier(
    ref.watch(apiProvider),
    ref.watch(wsProvider),
    key.convId,
    key.agentId,
    ref.watch(authProvider.select((s) => s.user?.id ?? '')),
  );
});
