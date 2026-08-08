import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/conversation.dart' show SessionMeta;
import '../models/message.dart';
import '../models/msg_type.dart';
import '../models/quote.dart';
import '../models/user.dart';
import '../models/ws_message.dart';
import '../rendering/card_renderer.dart';
import '../services/api_service.dart';
import '../services/local_message_store_abstract.dart';
import '../services/websocket_service.dart';
import 'auth_provider.dart';
import 'chat_state.dart';
import 'local_message_store_provider.dart';
import 'settings_provider.dart';

class ChatNotifier extends StateNotifier<ChatState> {
  final ApiService api;
  final WebSocketService ws;
  final String conversationId;
  final String? agentId;
  /// 当前 user.id，用于乐观更新消息的 senderId（user-user 会话按 senderId 区分自己/对方，
  /// 空字符串占位会导致消息显示在对方侧，见 chat_page.dart isMe 判断）。
  final String currentUserId;
  /// F4: 本地消息缓存。可选,默认 null(测试 + store 未 ready 时)。
  /// 非空时:_initialize 优先从 DB 即时呈现 → 增量拉 server → 写回 DB;
  /// loadMoreHistory 优先从 DB 读更老消息,DB 命中整页跳过 server。
  final LocalMessageStore? store;

  /// 当前登录用户(可空)。_appendOptimisticMessage 用它填 senderName + senderAvatarUrl,
  /// 让 sending 状态的乐观消息也能正确显示头像(避免字母色块 fallback)。
  final User? currentUser;

  StreamSubscription<WSMessage>? _subscription;
  StreamSubscription<WSMessage>? _updateSubscription;
  StreamSubscription<WSMessage>? _messageReadSub;
  StreamSubscription<WSMessage>? _sessionMetaSub;
  /// op=14 STREAM 流式占位订阅。占位/累加/终态替换的主驱动。
  StreamSubscription<Map<String, dynamic>>? _streamSub;
  Timer? _metaRefreshTimer;

  static const int _pageSize = 10;

  ChatNotifier(this.api, this.ws, this.conversationId, this.agentId, this.currentUserId,
      {this.store, this.currentUser})
      : super(const ChatState()) {
    CardContentRenderer.onDecide = (approvalId, actionId, reason) {
      return api.decideApproval(approvalId, actionId, reason: reason);
    };
    _initialize();
    _listenWS();
    _listenUpdates();
    _listenMessageRead();
    _listenSessionMetaUpdate();
    _listenStream();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _updateSubscription?.cancel();
    _messageReadSub?.cancel();
    _sessionMetaSub?.cancel();
    _streamSub?.cancel();
    _metaRefreshTimer?.cancel();
    // F6: 清理 static 回调（方案 B 过渡实现）。
    // 已知边界：多 ChatNotifier 并存时（如多 ChatPage 叠栈），后构造的覆盖
    // 先构造的 closure；先构造的 dispose 会把当前 closure 清成 null，
    // 让存活实例的审批按钮变 no-op。方案 A（实例字段）推迟到 F5 重构。
    CardContentRenderer.onDecide = null;
    super.dispose();
  }

  /// 刷新 sessionMeta（agent 消息到达后 2s 防抖调用）。
  /// plugin 在 agent 响应时可能更新了 mode/model/variant，
  /// 重新拉 getConversation 同步到 ChatState。
  /// OC 优先：如果 server mode 与 modeOverride 不同，清除 override。
  /// model override 清除：server 回流的 modelId/providerId 与 override 一致时清除
  /// （表示 OC 已采纳,本地 override 不再需要,避免重复触发）。
  void _refreshSessionMeta() {
    _metaRefreshTimer?.cancel();
    _metaRefreshTimer = Timer(const Duration(seconds: 2), () async {
      try {
        final conv = await api.getConversation(conversationId);
        final serverMode = conv.sessionMeta?.mode ?? '';
        final override = state.modeOverride;
        final shouldClearOverride =
            override != null && serverMode.isNotEmpty && override != serverMode;
        final serverModelId = conv.sessionMeta?.modelId ?? '';
        final serverProviderId = conv.sessionMeta?.providerId ?? '';
        final modelOverride = state.modelOverride;
        final shouldClearModelOverride = modelOverride != null &&
            serverModelId.isNotEmpty &&
            serverModelId == modelOverride.modelID &&
            serverProviderId == modelOverride.providerID;
        state = state.copyWith(
          convType: conv.type,
          convTitle: conv.displayName,
          sessionMeta: conv.sessionMeta,
          directory: conv.directory,
          clearModeOverride: shouldClearOverride,
          clearModelOverride: shouldClearModelOverride,
        );
      } catch (e) {
        debugPrint('[chatInit] refreshSessionMeta fail: $e');
      }
    });
  }

  /// 当前生效的 model:优先本地 override（用户刚切,等 server 采纳），
  /// 否则 fallback 到 sessionMeta 持久态（server 回流的 modelId/providerId）。
  /// OC 优先策略会把已被 server 采纳的 override 清空（_refreshSessionMeta），
  /// 此时正常对话只能靠 sessionMeta 兜底——compact 命令触发的 _model 字段必须读这里。
  /// sendText / sendSlash 共用，避免 sendSlash 漏 _model 导致 compact fail-fast。
  ModelOverride? get _effectiveModel {
    final override = state.modelOverride;
    if (override != null) return override;
    final meta = state.sessionMeta;
    if (meta == null) return null;
    if (meta.modelId.isEmpty || meta.providerId.isEmpty) return null;
    return ModelOverride(
      providerID: meta.providerId,
      modelID: meta.modelId,
      modelName: meta.modelName,
      providerName: meta.providerName,
    );
  }

  /// APP 端点击 SessionMetaStrip model 段选模型。
  /// 设置本地 modelOverride,SessionMetaStrip 立即渲染新模型名。
  /// _refreshSessionMeta 拉取后如果 server model 与 override 一致则清除（OC 优先）。
  void selectModel(ModelOverride override) {
    state = state.copyWith(modelOverride: override);
  }

  /// APP 端点击切换 Build↔Plan。
  void toggleMode() {
    final meta = state.sessionMeta;
    if (meta == null) return;
    final currentMode = state.modeOverride ?? meta.mode;
    final newMode = currentMode.toLowerCase() == 'build' ? 'plan' : 'build';
    state = state.copyWith(modeOverride: newMode);
  }

  /// 初始化：获取未读信息 → 拉首屏消息 → 定位。
  ///
  /// 有未读时用 firstUnreadCreatedAt 直接作 before 游标（不再用 _findMessageById
  /// 拉 N 条找 id，那个方案在未读 > N 时会失效）。
  /// 拉取结果用 _mergeHistory 合并，保留初始化期间 WS 并发到达的新消息
  /// （沿用现有防并发设计，避免直接覆盖丢失数据）。
  Future<void> _initialize() async {
    debugPrint('[chatInit] START convId=$conversationId');

    // F4: 优先从 DB 即时呈现(失败 silently,不阻塞原 unread 四象限逻辑)。
    // server 仍是真相源,原 unread 四象限(unreadCount==0 拉最新 /
    // unreadCount>0 用 firstUnreadCreatedAt-1ms 作 after 游标反向拉)保持不变,
    // DB 仅作「即时呈现 + 写回缓存」加速层。
    // 注意:eager 呈现不设 unreadCount/showUnreadSeparator/firstUnreadMessageId,
    // 这是过渡态,server 拉取后会校正 unread 四象限状态(几百 ms 窗口)。
    // 此期间 hasMore=true 与 unreadCount=0 看似不一致,属于过渡态预期行为。
    if (store != null) {
      // 先读 conversation 缓存(convType 必须在 messages state 之前拿到,
      // 否则 builder 先看到 convType=null 渲染带头像,再切回无头像 → 闪一下)。
      String? cachedConvType;
      String? cachedConvTitle;
      try {
        final cached = await store!.getConversation(currentUserId, conversationId);
        if (cached != null) {
          cachedConvType = cached.type;
          cachedConvTitle = cached.displayName;
        } else {
          // fallback:putConversations 可能删除了 agent_session 条目,用 meta 兜底
          final meta = await store!.getConversationMeta(currentUserId, conversationId);
          if (meta != null) {
            cachedConvType = meta.type;
            cachedConvTitle = meta.title;
          }
        }
      } catch (e) {
        debugPrint('[localdb] _initialize eager getConversation fail: $e');
      }

      try {
        final local = await store!.getMessages(
            conversationId: conversationId, limit: _pageSize);
        if (local.isNotEmpty) {
          state = _mergeHistory(local).copyWith(
            hasMore: true,
            isInitialLoading: false,
            convType: cachedConvType,
            convTitle: cachedConvTitle,
          );
          final nullNames =
              state.displayMessages.where((m) => m.senderName == null).length;
          debugPrint('[chatInit] DB hit ${local.length} msgs, presented eagerly; '
              'null senderName=$nullNames/${state.displayMessages.length}');
        } else if (cachedConvType != null) {
          // 无消息但有 conversation 缓存(理论上不会发生,兜底)
          state = state.copyWith(
            convType: cachedConvType,
            convTitle: cachedConvTitle,
          );
        }
      } catch (e) {
        debugPrint('[localdb] _initialize eager getMessages fail: $e');
      }
    }

    try {
      // 拉取会话详情获取 type（agent_session 被 ListForUser 排除，
      // conversationProvider 里没有，ChatPage 排版依赖此 type）。
      // 失败 silently（不影响核心消息加载）。
      try {
        final convDetail = await api.getConversation(conversationId);
        state = state.copyWith(
          convType: convDetail.type,
          convTitle: convDetail.displayName,
          sessionMeta: convDetail.sessionMeta,
          directory: convDetail.directory,
        );
        debugPrint('[chatInit] getConversation ok: type=${convDetail.type}, title=${convDetail.displayName}, meta=${convDetail.sessionMeta?.toJson()}');
        // 写回 store:下次离线进入时 eager 阶段可读出 type/title/meta 兜底
        // (agent_session 被 ListForUser 排除,只能靠此缓存)。
        if (store != null) {
          try {
            await store!.putConversation(currentUserId, convDetail);
            // 独立 meta 缓存,不被 putConversations 删除,离线防闪头像用
            await store!.putConversationMeta(currentUserId, conversationId, convDetail.type, convDetail.displayName);
          } catch (e) {
            debugPrint('[localdb] putConversation fail: $e');
          }
        }
      } catch (e) {
        debugPrint('[chatInit] getConversation fail: $e');
      }

      // getUnreadInfo 已返 UnreadInfo model(Task 16),无需手动 fromJson
      final unread = await api.getUnreadInfo(conversationId);
      debugPrint('[chatInit] getUnreadInfo raw=$unread');
      debugPrint('[chatInit] unread parsed: count=${unread.unreadCount}, '
          'firstUnreadId=${unread.firstUnreadMessageId}, '
          'firstUnreadCreatedAt=${unread.firstUnreadCreatedAt}, '
          'hasMoreBeforeFirstUnread=${unread.hasMoreBeforeFirstUnread}');

      if (unread.unreadCount == 0) {
        // 无未读：拉最新 20 条
        debugPrint('[chatInit] BRANCH: no unread');
        // API 已返 List<ChatMessage>(Task 16),无需手动 fromJson。
        final loaded = await api.getMessagesBefore(conversationId, limit: _pageSize);
        debugPrint('[chatInit] noUnread loaded ${loaded.length} msgs');
        state = _mergeHistory(loaded).copyWith(
          hasMore: loaded.length == _pageSize,
          unreadCount: 0,
          isInitialLoading: false,
          isServerInitialized: true,
        );
        debugPrint('[chatInit] noUnread state set: hasMore=${state.hasMore}, '
            'displayMessages=${state.displayMessages.length}');
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
        // API 已返 List<ChatMessage>(ASC,Task 16),无需手动 fromJson。
        final listAsc = await api.getMessagesAfter(
          conversationId,
          after: after,
          limit: _pageSize,
        );
        debugPrint('[chatInit] getMessagesAfter returned ${listAsc.length} msgs');
        // ListAfter 返回 ASC，reverse 成 newest first 配合 reverse ListView
        final loaded = listAsc.reversed.toList();
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
          isServerInitialized: true,
        );
        debugPrint('[chatInit] hasUnread state set: hasMore=$hasMore, '
            'firstUnreadMessageId=${state.firstUnreadMessageId}, '
            'unreadCount=${state.unreadCount}, '
            'displayMessages=${state.displayMessages.length}, '
            'historyLast(=最老,应等于firstUnread)=${state.historyMessages.isEmpty ? null : state.historyMessages.last.id}');
      }

      // F4: 把 server 拉到的消息写 DB(失败 silently,不影响 state)。
      // server 仍是真相源,DB 只是缓存层。
      // drift insertOrReplace 幂等,重复 id 自然覆盖,无需先查 existingIds
      // (避免每次进会话拉 9999 行 ID,低端 Android 卡顿 + 长会话漏判)
      if (store != null) {
        try {
          if (state.displayMessages.isNotEmpty) {
            await store!.putMessages(state.displayMessages);
          }
        } catch (e) {
          debugPrint('[localdb] _initialize putMessages fail: $e');
        }
      }
    } catch (e, st) {
      debugPrint('[chatInit] EXCEPTION: $e\n$st');
      // 兜底：拉最新消息（定位/高亮全部放弃，保证列表可用）
      // API 已返 List<ChatMessage>(Task 16),无需手动 fromJson。
      final loaded = await api.getMessages(conversationId, limit: _pageSize, offset: 0);
      state = _mergeHistory(loaded).copyWith(
        hasMore: loaded.length == _pageSize,
        isInitialLoading: false,
        isServerInitialized: true,
      );
      debugPrint('[chatInit] fallback state set: hasMore=${state.hasMore}, '
          'displayMessages=${state.displayMessages.length}');
    }
  }

  /// 把网络加载的消息合并进 state。保留 state 中并发 WS 到达、但网络结果
  /// 中未包含的新消息（如 _initialize 的 API 调用期间 WS 新增的消息），
  /// 避免直接覆盖丢失数据。
  ///
  /// **按 createdAt 降序排序**（newest first）消除对 extra/loaded 新旧关系的
  /// 假设：_initialize 场景下 extra 是 WS 推送的更新消息（[extra, loaded] 正确），
  /// 但 jumpToBottom 场景下 extra 是较老的历史（顺序反了，最老历史会被推到
  /// historyMessages[0] = 视觉底部，表现为「历史压在最新消息下方」）。排序后两种场景
  /// 都正确，O(n log n) 成本可接受（n ≤ 几百）。
  ///
  /// **loadedIds 用 loaded 全部 id（不是 filtered 后的 id）**：
  /// loaded 里被 _filterDisplayable 过滤的消息（如终态子审批卡），其 id 仍然
  /// 要让 extra 排除掉对应的 historyMessages 旧版本。否则旧版本（可能是 eager
  /// DB read 出的脏数据 parent_msg_id=NULL）会经 extra 被保留进 merged，
  /// 既漏出主会话框，又被 putMessages 回写 DB 形成自维持脏数据循环。
  ChatState _mergeHistory(List<ChatMessage> loaded) {
    final loadedIds = loaded.map((m) => m.id).toSet();
    final filtered = _filterDisplayable(loaded);
    final extra = _filterDisplayable(
      // extra 只从 historyMessages 取(与活跃 liveMessages 隔离,无需 isStreaming 排除)。
      // 竞态场景(_initialize 异步窗口内 STREAM 到达插占位到 live):server 历史不覆盖
      // live 占位,由 _onMessageCreate 终态到达时清理(race fix 分支)。
      state.historyMessages.where((m) => !loadedIds.contains(m.id)),
    );
    final merged = [...extra, ...filtered];
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt)); // newest first
    // 清理 live 中残留的 isStreaming 占位:_mergeHistory 由 _initialize / jumpToBottom
    // 触发,server 历史是真相源(只含终态)。窗口期内 STREAM 插的占位若终态已在 history
    // (或终态尚未入库的活跃流),此处统一移除;活跃流的下个 STREAM delta 会经
    // _listenStream 的 idx<0 分支重建占位,不丢内容(对齐旧架构 messages=merged 整体替换)。
    final liveCleaned = state.liveMessages.where((m) => !m.isStreaming).toList();
    return state.copyWith(
      historyMessages: merged,
      liveMessages:
          liveCleaned.length != state.liveMessages.length ? liveCleaned : null,
    );
  }

  /// 用户主动滑到底部时标记已读：清未读计数 + 分割线 + firstUnread，
  /// 调 markConversationRead 同步服务端。**不重拉数据**（用户已在底部，
  /// displayMessages 已包含最新消息，无需 jumpToBottom 那种「丢弃历史上下文」）。
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
  ///
  /// F4: 优先从 DB 读更老消息,DB 命中整页(>=_pageSize)跳过 server;
  /// DB 不够才走 server 拉,拉到后写回 DB。
  Future<void> loadMoreHistory() async {
    debugPrint('[loadMore] CALLED: isLoadingMore=${state.isLoadingMore}, '
        'hasMore=${state.hasMore}, displayMessages=${state.displayMessages.length}');
    if (state.isLoadingMore || !state.hasMore || state.displayMessages.isEmpty) {
      debugPrint('[loadMore] ABORT: guard failed');
      return;
    }

    state = state.copyWith(isLoadingMore: true);

    // oldest = history 末尾(最老历史);history 为空(刚进会话只有 live)fallback 到
    // live 头部(live oldest-first,[0]=最旧活跃)。
    final oldest = state.historyMessages.isNotEmpty
        ? state.historyMessages.last
        : state.liveMessages.first;
    debugPrint('[loadMore] oldest.id=${oldest.id}, oldest.createdAt=${oldest.createdAt}');
    try {
      // F4: DB 即时呈现(加速 UI 响应),server 仍然拉校正。
      // 不直接跳过 server 是为了避免 DB 内部 hole(server 之前拉失败留断片):
      // 若 DB 命中 >= pageSize 就跳 server,hole 会永远存在,后续 loadMore 都从 DB
      // 命中更老的,hole 始终不被填上。这里把 DB 当「即时呈现」加速层,不当「跳过 server」依据。
      List<ChatMessage> older = const [];
      if (store != null) {
        try {
          older = _filterDisplayable(await store!.getMessages(
            conversationId: conversationId,
            before: oldest.createdAt,
            limit: _pageSize,
          ));
          debugPrint('[loadMore] DB hit ${older.length} older msgs');
        } catch (e) {
          debugPrint('[localdb] loadMore getMessages fail: $e');
        }
      }

      // DB 即时呈现:先合并 older 进 history(去重防 older 与现有消息重复)
      if (older.isNotEmpty) {
        final existingIds = state.displayMessages.map((m) => m.id).toSet();
        final dedupedOlder =
            older.where((m) => !existingIds.contains(m.id)).toList();
        if (dedupedOlder.isNotEmpty) {
          state = state.copyWith(
            historyMessages: [...state.historyMessages, ...dedupedOlder],
            hasMore: true,
          );
        }
      }

      // server 拉(无论 DB 命中与否,都校正一次以填 hole)
      // API 已返 List<ChatMessage>(Task 16),无需手动 fromJson。
      final remoteRaw = await api.getMessagesBefore(
        conversationId,
        before: oldest.createdAt,
        limit: _pageSize,
      );
      // 过滤 silent 回复（显示用），hasMore 判断用未过滤的 raw 长度，
      // 避免整页混入回复时计数缩水误判 hasMore=false。
      final remote = _filterDisplayable(remoteRaw);
      debugPrint('[loadMore] fetched ${remote.length} older msgs from server');
      if (store != null) {
        try {
          await store!.putMessages(remoteRaw);
        } catch (e) {
          debugPrint('[localdb] loadMore putMessages fail: $e');
        }
      }
      // server 拉的结果合并:对当前 state 去重(可能已含 DB older)
      final currentIds = state.displayMessages.map((m) => m.id).toSet();
      final dedupedRemote =
          remote.where((m) => !currentIds.contains(m.id)).toList();
      state = state.copyWith(
        historyMessages: [...state.historyMessages, ...dedupedRemote],
        hasMore: remoteRaw.length == _pageSize,
        isLoadingMore: false,
      );
      debugPrint('[loadMore] DONE: new hasMore=${state.hasMore}, '
          'displayMessages=${state.displayMessages.length}');
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
      // API 已返 List<ChatMessage>(Task 16),无需手动 fromJson。
      final loaded = await api.getMessagesBefore(conversationId, limit: _pageSize);
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
    // 子 agent 事件(parent_msg_id 非空)不在主聊天列表展示。server HTTP 列表
    // 已用 parent_msg_id IS NULL 过滤,WS 实时路径同样需过滤,否则子 agent 的
    // reasoning/tool_calls 会实时涌入主聊天,刷新后又消失,造成闪烁/不一致。
    if (msgData['parent_msg_id'] != null && !_isPendingChildApprovalCard(msgData)) return;

    // 流式终态替换:server 在终态 MESSAGE_CREATE 的 content.data._stream_id 标记
    // 该消息对应的 STREAM 流 id。client 同位置替换 `stream:$streamId` 占位,
    // 避免占位与终态并存闪烁。_stream_id 是瞬态控制字段,终态消息不保留
    // (enrich/dedup 路径会污染),先剥离再 fromJson。
    final rawContent = msgData['content'] as Map<String, dynamic>?;
    final rawData = rawContent?['data'] as Map<String, dynamic>?;
    final streamId = rawData?['_stream_id'] as String?;

    final ChatMessage effective;
    if (streamId != null) {
      final cleanData = Map<String, dynamic>.from(rawData!);
      cleanData.remove('_stream_id');
      final cleanContent = Map<String, dynamic>.from(rawContent!);
      cleanContent['data'] = cleanData;
      final cleaned = Map<String, dynamic>.from(msgData);
      cleaned['content'] = cleanContent;
      effective = ChatMessage.fromJson(cleaned);
    } else {
      effective = ChatMessage.fromJson(msgData);
    }

    // silent 控制回复（permission_reply / question_reply）不入列表：
    // 见 _filterDisplayable 根因说明。
    // step_finish:finished=true 主循环汇总条放行(渲染 tokens 小字 + 作未读锚点),
    // 中间推理步(finished 缺失)继续过滤(过程元数据不打扰)。见 _filterDisplayable。
    final t = MsgTypeX.fromString(effective.content['msg_type'] as String?);
    if (t == MsgType.permissionReply ||
        t == MsgType.questionReply ||
        (t == MsgType.stepFinish && !_isMainLoopStepFinish(effective.content))) {
      return;
    }

    // 流式终态预处理(race fix):streamId 非空时,live 可能已有占位需替换/清理。
    // 必须在 dedup 之前处理:dedup 会因 history 已含终态(_mergeHistory race 拉入)
    // 提前 return,导致 live 占位残留 → displayMessages 双显(占位 + history 终态)。
    if (streamId != null) {
      final placeholderId = 'stream:$streamId';
      final liveIdx = state.liveMessages.indexWhere((m) => m.id == placeholderId);
      final finalText =
          (effective.content['data'] as Map?)?['text'] as String? ?? '';
      if (liveIdx >= 0) {
        final histHasTerminal =
            state.historyMessages.any((m) => m.id == effective.id);
        if (histHasTerminal) {
          // race: _initialize 异步窗口内 STREAM 插占位 + server 历史已含终态。
          // 仅清 live 占位(不重复插 live,避免 displayMessages 双显)。
          state = _removeMessageByIds({placeholderId});
          debugPrint('[SSE-DBG] _onMessageCreate 终态已在 history(race),清 live 占位 sid=$streamId msgId=${effective.id}');
        } else {
          // 正常: live 占位同位置替换为终态(避免占位与终态并存闪烁)。
          state = _updateMessageById(placeholderId, (_) => effective);
          debugPrint('[SSE-DBG] _onMessageCreate 终态替换占位 OK sid=$streamId len=${finalText.length} msgId=${effective.id}');
        }
        if (effective.senderType == 'agent') _refreshSessionMeta();
        return;
      }
      debugPrint('[SSE-DBG] _onMessageCreate 终态无占位(滞留?) sid=$streamId len=${finalText.length} msgId=${effective.id}');
      // fall through 到正常 dedup + 插入(占位不存在:刚进会话未收 STREAM 等场景)
    }

    // 去重:双 list 任一含 effective.id 即跳过(server echo / 占位已替换为终态等)
    if (state.liveMessages.any((c) => c.id == effective.id) ||
        state.historyMessages.any((c) => c.id == effective.id)) {
      return;
    }

    // 自 echo 去重：sendText/sendFile/sendSlash 已插入乐观消息（local_ 前缀,只进 live）。
    // WS echo 若先于 HTTP response 到达，_onMessageCreate 插入 server 消息后
    // _replaceLocalWithServerId 又将 localId 替换为 serverId，导致同一消息
    // 有两份副本叠加后删除，产生抖动。跳过 self-echo 让替换流程安全完成。
    if (effective.senderId == currentUserId &&
        state.liveMessages.any((m) =>
            m.id.startsWith('local_') && m.senderId == effective.senderId)) {
      debugPrint('[wsMsg] SKIP self-echo (local pending): ${effective.id}');
      return;
    }

    state = state.copyWith(
      liveMessages: _insertLiveKeepingStreamingLast(state.liveMessages, effective),
    );

    // agent 消息到达后刷新 sessionMeta（plugin 可能更新了 mode/model/variant）
    if (effective.senderType == 'agent') {
      _refreshSessionMeta();
    }
  }

  /// 订阅 op=14 STREAM 流式 delta。占位/累加/终态替换的主驱动。
  ///
  /// 协议:
  /// - 首块 STREAM:插占位消息 id=`stream:$streamId`,isStreaming=true,
  ///   senderId 取本会话 agentId(让头像/字母色块渲染对齐 agent)。
  /// - 后续 STREAM:同位置 copyWith 替换 content.data.text(累积全量),不新增行。
  /// - 终态:由 [_onMessageCreate] 处理 MESSAGE_CREATE 带 _stream_id 的同位替换。
  ///
  /// 仅处理本会话事件(conversation_id 匹配),其他会话忽略。
  void _listenStream() {
    _streamSub = ws.streamEvents.listen((d) {
      final convId = d['conversation_id'] as String?;
      if (convId == null || convId != conversationId) return;
      final streamId = d['stream_id'] as String?;
      if (streamId == null) return;
      final text = d['text'] as String? ?? '';
      final msgType = d['msg_type'] as String? ?? 'reasoning';

      // 协议边界(防御性过滤):plugin PartDispatcher 只对 reasoning/text part
      // 生成 streamId 并推 sendStream(msg_type 仅 reasoning/markdown,见
      // part_dispatcher.ts 的 maybeFlushStream);step_finish 等走独立 case
      // 不经流式通道。此处只放行文本类(reasoning/markdown/text),其它 msg_type
      // 直接 return — 防御未来 plugin 误发非文本 STREAM 导致占位永久滞留
      // (终态 MESSAGE_CREATE 在 _onMessageCreate 的过滤链会 return,占位无法被替换)。
      final t = MsgTypeX.fromString(msgType);
      if (t != MsgType.reasoning &&
          t != MsgType.markdown &&
          t != MsgType.text) {
        return;
      }

      // 聚合模式元素级流式:op=14 帧带 aggregate{message_id, element_id} 时,
      // 不建独立占位,直接更新聚合卡消息内对应元素的 data.text(全量替换)。
      // 元素最终内容仍由 plugin patchElements 的 MESSAGE_UPDATE 持久化兜底,
      // 此处仅实时刷新正在观看会话的 user 端。无 aggregate 字段走旧占位逻辑。
      final aggregate = d['aggregate'] as Map<String, dynamic>?;
      if (aggregate != null) {
        _applyAggregateStreamUpdate(aggregate, text);
        return;
      }

      final placeholderId = 'stream:$streamId';
      final idx = state.liveMessages.indexWhere((m) => m.id == placeholderId);
      final newContent = <String, dynamic>{
        'msg_type': msgType,
        'data': {'text': text},
      };
      if (idx >= 0) {
        // 后续块:替换占位 text(单 list 更新,不新增行)
        state = _updateMessageById(
            placeholderId, (m) => m.copyWith(content: newContent));
        debugPrint('[SSE-DBG] _listenStream 替换占位 sid=$streamId len=${text.length}');
      } else {
        // 首块:插占位到 live
        final placeholder = ChatMessage(
          id: placeholderId,
          conversationId: conversationId,
          senderType: 'agent',
          senderId: agentId ?? '',
          content: newContent,
          createdAt: DateTime.now(),
          isStreaming: true,
        );
        state = state.copyWith(
          liveMessages: [...state.liveMessages, placeholder],
        );
        debugPrint('[SSE-DBG] _listenStream 新建占位 sid=$streamId len=${text.length}');
      }
    });
  }

  /// 聚合卡元素级流式更新：定位聚合卡消息（id == aggregate.message_id 且
  /// msg_type == aggregate_card），全量替换 element_id 匹配元素的 data.text。
  ///
  /// 找不到聚合卡（流式帧早于建卡 MESSAGE_CREATE 到达 / 元素未就绪）时静默丢弃：
  /// 元素最终内容由 plugin patchElements 的 MESSAGE_UPDATE 持久化兜底，不丢数据。
  /// 与 plugin patch 语义一致：全量替换 elements[]（非增量 diff）。
  void _applyAggregateStreamUpdate(Map<String, dynamic> aggregate, String text) {
    final messageId = aggregate['message_id'] as String?;
    final elementId = aggregate['element_id'] as String?;
    if (messageId == null ||
        messageId.isEmpty ||
        elementId == null ||
        elementId.isEmpty) {
      return;
    }

    // 定位聚合卡消息（live/history 双 list 任一命中即可）
    ChatMessage? card;
    for (final m in state.liveMessages) {
      if (m.id == messageId &&
          MsgTypeX.fromString(m.content['msg_type'] as String?) ==
              MsgType.aggregateCard) {
        card = m;
        break;
      }
    }
    if (card == null) {
      for (final m in state.historyMessages) {
        if (m.id == messageId &&
            MsgTypeX.fromString(m.content['msg_type'] as String?) ==
                MsgType.aggregateCard) {
          card = m;
          break;
        }
      }
    }
    if (card == null) return;

    final data = card.content['data'] as Map<String, dynamic>? ?? const {};
    final rawElements = data['elements'] as List?;
    if (rawElements == null) return;

    // 全量替换 elements[],element_id 匹配的元素 data.text 整体替换
    final newElements = <Map<String, dynamic>>[];
    var matched = false;
    for (final raw in rawElements) {
      if (raw is! Map) continue;
      final e = Map<String, dynamic>.from(raw);
      if (e['element_id'] == elementId) {
        final eData = Map<String, dynamic>.from(e['data'] as Map? ?? const {});
        eData['text'] = text;
        e['data'] = eData;
        matched = true;
      }
      newElements.add(e);
    }
    if (!matched) return;

    final newContent = <String, dynamic>{
      'msg_type': MsgType.aggregateCard.value,
      'data': {...data, 'elements': newElements},
    };
    state = _updateMessageById(messageId, (m) => m.copyWith(content: newContent));
    debugPrint('[SSE-DBG] _listenStream 聚合元素更新 msgId=$messageId element=$elementId len=${text.length}');
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
          // !m.isRecalled 守卫:已切过的不再处理(防 optimistic + dispatch 双切)。
          final senderName = msgData['sender_name'] as String? ?? '';
          for (final id in ids) {
            state = _updateMessageById(
                id,
                (m) => m.isRecalled
                    ? m
                    : m.copyWith(isRecalled: true, recalledByName: senderName));
          }
        } else {
          // hide:直接从双 list 移除(只对我消失)
          state = _removeMessageByIds(ids);
        }
        return;
      }
      _onMessageCreate(m.d as Map<String, dynamic>);
    });
  }

  /// 新消息插入 live 时保持不变量:isStreaming 占位(busy 气泡)恒在数组末尾。
  ///
  /// 双 sliver 下 live 区渲染顺序 = liveMessages 数组顺序,index 越大越靠下。
  /// 流式占位由 _listenStream append 到末尾(恒在底部);若普通新消息(卡片等)也
  /// append,思考中到达的卡片会排到 busy 占位下方,视觉上「先出现在底部再被校正
  /// 回弹」(闪烁)。正确语义:新消息插到第一个 isStreaming 占位之前(上方)。
  /// 用户消息按实际时序 append(聚合卡下方)——聚合卡按用户消息拆分由 plugin
  /// 侧负责(用户消息打断旧卡定格),APP 只保证 isStreaming 占位恒在末尾。
  List<ChatMessage> _insertLiveKeepingStreamingLast(
      List<ChatMessage> live, ChatMessage msg) {
    final streamIdx = live.indexWhere((m) => m.isStreaming);
    if (streamIdx < 0) return [...live, msg];
    return [...live.take(streamIdx), msg, ...live.skip(streamIdx)];
  }

  /// 按 id 在双 list(liveMessages + historyMessages)同步更新单条消息。
  /// 用于 content 替换 / recall / markFailed / retrySend / id 映射等变更路径。
  /// 仅命中 list 的对应槽位被替换(用 indexWrite 找首个匹配),未命中保持不变。
  /// 返回新的 ChatState(未命中任一 list 时返回的 state 与原 state 内容相同但是新实例)。
  ChatState _updateMessageById(
      String id, ChatMessage Function(ChatMessage) update) {
    var live = state.liveMessages;
    var hist = state.historyMessages;
    final li = live.indexWhere((m) => m.id == id);
    if (li >= 0) live = List.of(live)..[li] = update(live[li]);
    final hi = hist.indexWhere((m) => m.id == id);
    if (hi >= 0) hist = List.of(hist)..[hi] = update(hist[hi]);
    return state.copyWith(
      liveMessages: li >= 0 ? live : null,
      historyMessages: hi >= 0 ? hist : null,
    );
  }

  /// 按 ids 从双 list 同步移除。用于 hide / delete / removeLocal / 终态子卡移除等。
  ChatState _removeMessageByIds(Set<String> ids) {
    return state.copyWith(
      liveMessages:
          state.liveMessages.where((m) => !ids.contains(m.id)).toList(),
      historyMessages:
          state.historyMessages.where((m) => !ids.contains(m.id)).toList(),
    );
  }

  /// 聚合卡 MESSAGE_UPDATE 增量 op 应用:delta(广播 content)形如
  /// `{msg_type:"aggregate_card", data:{op, ...}}`,把 op 合并进本地 content:
  ///   - append:     data.element 追加到 elements 末尾
  ///   - update:     data.element_id 命中的元素 data 整体替换(data.data)
  ///   - remove:     data.element_id 删除元素(不存在幂等跳过,便于网络重试)
  ///   - reorder:    data.order 重排(未列出的元素保序追加尾部,不丢数据)
  ///   - set_state:  data.state 改 data.state
  ///   - set_silent: data.silent 改顶层 content.silent(注意 delta 的 silent
  ///                 在 data 内,合并结果放 content 顶层,与 server 落库结构一致)
  ///
  /// 返回合并后的全量 content;返回 null 表示非增量(delta 无 op / 原消息非
  /// aggregate_card),调用方走全量替换兼容路径(旧 plugin / 非聚合卡)。
  /// 增量参数缺失 / 目标元素不存在时幂等跳过(返回原 content):本地状态可能
  /// 滞后(断线漏 append),此时若用 delta 全量替换会清掉整卡元素。
  /// schema_ver 守卫:本地 content.data.schema_ver 缺失视为 1,> 当前支持的
  /// aggregateCardSchemaVer 时不应用增量(保持现状),防止新协议增量被旧 APP 误合并。
  Map<String, dynamic>? _applyAggregateCardDelta(
      Map<String, dynamic> content, Map<String, dynamic> delta) {
    if (MsgTypeX.fromString(content['msg_type'] as String?) !=
        MsgType.aggregateCard) {
      return null;
    }
    final data = delta['data'];
    if (data is! Map) return null;
    final op = data['op'] as String?;
    if (op == null || op.isEmpty) return null;

    // schema_ver 守卫:本地 content 版本超前(新插件协议)→ 不应用增量,防误合并。
    final localVer = (content['data'] as Map?)?['schema_ver'];
    final localVerInt = localVer is int ? localVer : 1;
    if (localVerInt > aggregateCardSchemaVer) return content;

    final newData =
        Map<String, dynamic>.from(content['data'] as Map? ?? const {});
    final newContent = <String, dynamic>{...content, 'data': newData};

    switch (op) {
      case 'append':
        final element = data['element'];
        if (element is! Map) return content;
        final raw = newData['elements'];
        final elements = raw is List ? [...raw] : <Object>[];
        elements.add(Map<String, dynamic>.from(element));
        newData['elements'] = elements;
      case 'update':
        final elementId = data['element_id'] as String?;
        final patchData = data['data'];
        if (elementId == null || elementId.isEmpty || patchData is! Map) {
          return content;
        }
        final raw = newData['elements'];
        if (raw is! List) return content;
        var matched = false;
        final elements = raw.map((e) {
          if (e is Map && e['element_id'] == elementId) {
            matched = true;
            return <String, dynamic>{...e, 'data': Map<String, dynamic>.from(patchData)};
          }
          return e;
        }).toList();
        if (!matched) return content;
        newData['elements'] = elements;
      case 'remove':
        final elementId = data['element_id'] as String?;
        if (elementId == null || elementId.isEmpty) return content;
        final raw = newData['elements'];
        if (raw is! List) return content;
        newData['elements'] = raw
            .where((e) => !(e is Map && e['element_id'] == elementId))
            .toList();
      case 'reorder':
        final order = data['order'];
        if (order is! List || order.isEmpty) return content;
        final raw = newData['elements'];
        if (raw is! List) return content;
        final byId = <Object?, Object>{
          for (final e in raw)
            if (e is Map) e['element_id']: e,
        };
        final seen = <String>{};
        final ordered = <Object>[];
        for (final id in order) {
          final e = byId[id];
          if (e == null) continue; // 未知 id 幂等跳过(server 已校验,本地容错)
          if (seen.contains(id)) continue; // order 重复 id 去重
          seen.add(id);
          ordered.add(e);
        }
        for (final e in raw) {
          if (e is Map && seen.contains(e['element_id'])) continue;
          ordered.add(e);
        }
        newData['elements'] = ordered;
      case 'set_state':
        final state = data['state'] as String?;
        if (state == null || state.isEmpty) return content;
        newData['state'] = state;
      case 'set_silent':
        final silent = data['silent'];
        if (silent is! bool) return content;
        return <String, dynamic>{...newContent, 'silent': silent};
      default:
        return content; // 未知 op:幂等跳过,不覆盖本地
    }
    return newContent;
  }

  void _listenUpdates() {
    _updateSubscription = ws.messageUpdates.listen((msg) {
      final payload = msg.d as Map<String, dynamic>?;
      if (payload == null) return;
      if (payload['conversation_id'] != conversationId) return;

      final msgId = payload['message_id'] as String?;
      if (msgId == null) return;

      final newContent = payload['content'] as Map<String, dynamic>?;
      if (newContent == null) return;

      // 双 list 查找目标消息(任一命中即可)
      final liveIdx = state.liveMessages.indexWhere((m) => m.id == msgId);
      final histIdx = state.historyMessages.indexWhere((m) => m.id == msgId);
      if (liveIdx < 0 && histIdx < 0) return;
      final existing = liveIdx >= 0
          ? state.liveMessages[liveIdx]
          : state.historyMessages[histIdx];

      // pending 子审批卡收到终态(approved/denied/expired)→ 从列表移除。
      // 用户只关注 pending 的(贴 task 卡片下方),处理完即消失。
      final newStatus = (newContent['data'] as Map<String, dynamic>?)?['status'];
      if (newStatus != null && newStatus != 'pending') {
        final mt = MsgTypeX.fromString(newContent['msg_type'] as String?);
        final isChildApprovalCard = (mt == MsgType.permissionCard ||
                mt == MsgType.questionCard) &&
            existing.parentMsgId != null &&
            existing.parentMsgId!.isNotEmpty;
        if (isChildApprovalCard) {
          state = _removeMessageByIds({msgId});
          return;
        }
      }

      // 聚合卡增量 op:合并进本地 content,保持元素/state/silent 增量演进;
      // 非增量(无 op / 非聚合卡)走全量替换兼容(旧 plugin / 历史消息)。
      state = _updateMessageById(msgId, (m) {
        final merged = _applyAggregateCardDelta(m.content, newContent);
        return m.copyWith(content: merged ?? newContent);
      });
    });
  }

  /// 多端同步:其他端 markRead 后,server 推 MESSAGE_READ 给本端。
  /// 刷本会话的 unreadCount + firstUnreadMessageId(基于 server 真值的 message_ids),
  /// 让当前 ChatPage 立即切「已读样式」,不需退出再进重拉 UnreadInfo。
  /// 仅处理本会话事件(其他会话由 conversationProvider 处理徽章)。
  void _listenMessageRead() {
    _messageReadSub = ws.messageReads.listen((msg) {
      final payload = msg.d as Map<String, dynamic>?;
      if (payload == null) return;
      if (payload['conversation_id'] != conversationId) return;

      final newUnread = (payload['unread_count'] as num?)?.toInt() ?? 0;
      // newUnread=0 时清 firstUnreadMessageId(全部已读),否则保留(部分已读,
      // firstUnread 位置仍按 server 端 last_read_message_id 计算,client 端
      // 不易精确同步,留给下次 _initialize 拉 UnreadInfo 矫正)。
      // 注意:ChatState.copyWith 用 clearFirstUnread 标志位清 firstUnreadMessageId,
      // 直接传 firstUnreadMessageId: null 会被 ?? 当「未传」保留旧值。
      state = state.copyWith(
        unreadCount: newUnread,
        clearFirstUnread: newUnread == 0,
        showUnreadSeparator: newUnread == 0 ? false : state.showUnreadSeparator,
      );
    });
  }

  /// 监听 SESSION_META_UPDATE:plugin PATCH session-meta 后,server 广播给本会话
  /// user 端,直接整体替换 chatState.sessionMeta,实时刷新 SessionMetaStrip /
  /// EnvMetaStrip,不依赖 agent 消息触发的 2s 防抖拉取(原路径只能拉到 plugin
  /// 上次写入的快照,无法刷新 cwd/git_branch 等运行时变更)。
  ///
  /// OC 优先:server 回流的 mode/model 与 modeOverride/modelOverride 不一致时清除
  /// override(对齐 _refreshSessionMeta),避免本地 override 与 server 持久态漂移。
  void _listenSessionMetaUpdate() {
    _sessionMetaSub = ws.sessionMetaUpdates.listen((msg) {
      final payload = msg.d as Map<String, dynamic>?;
      if (payload == null) return;
      if (payload['conv_id'] != conversationId) return;

      final metaJson = payload['session_meta'];
      if (metaJson is! Map<String, dynamic>) return;
      final newMeta = SessionMeta.fromJson(metaJson);

      // OC 优先:server mode/model 与 override 不一致 → 清 override。
      final serverMode = newMeta.mode;
      final shouldClearMode = state.modeOverride != null &&
          serverMode.isNotEmpty &&
          state.modeOverride != serverMode;
      final serverModelId = newMeta.modelId;
      final serverProviderId = newMeta.providerId;
      final modelOverride = state.modelOverride;
      final shouldClearModel = modelOverride != null &&
          serverModelId.isNotEmpty &&
          serverModelId == modelOverride.modelID &&
          serverProviderId == modelOverride.providerID;

      state = state.copyWith(
        sessionMeta: newMeta,
        clearModeOverride: shouldClearMode,
        clearModelOverride: shouldClearModel,
      );
    });
  }

  /// 合并跨页跳转加载的消息到本地列表(去重 + 按时间倒序)。
  ///
  /// 用于 chat_page._jumpToMessage 远程加载场景:用户点击引用块,本地缓存
  /// 没有目标消息时,调 api.getMessageContext 拉 target + 前后 N 条,合并进来
  /// 让滚动定位能找到目标 index。
  ///
  /// - 入参 [ctx.before] 是时间倒序(最新在前),与 historyMessages 一致,直接拼接;
  /// - 入参 [ctx.after] 是时间正序(最老在前),拼接时反转为倒序;
  /// - 全部按 createdAt 降序重排(newest first),与 _mergeHistory 保持一致;
  /// - 已存在的 id(双 list 任一含)跳过(去重),全部已存在时不触发 rebuild。
  /// - 写入 historyMessages(跳转上下文是历史性内容,贴合历史 sliver 几何)。
  void mergeJumpedContext(MessageContext ctx) {
    final existing = {
      ...state.liveMessages.map((m) => m.id),
      ...state.historyMessages.map((m) => m.id),
    };
    final incoming = <ChatMessage>[];

    // ctx.before 已经是倒序,直接加
    for (final m in ctx.before) {
      if (existing.add(m.id)) incoming.add(m);
    }
    if (existing.add(ctx.target.id)) incoming.add(ctx.target);
    // ctx.after 是正序,反转成倒序后加
    for (final m in ctx.after.reversed) {
      if (existing.add(m.id)) incoming.add(m);
    }

    if (incoming.isEmpty) return; // 全部已存在,无需 rebuild

    final merged = [...state.historyMessages, ...incoming]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt)); // newest first
    state = state.copyWith(historyMessages: merged);
  }

  /// 设置待发送引用消息(user 长按消息选「引用」后调用)。
  /// 输入栏预览 state.pendingQuote,发送时合并到 content.data.quote.message_id。
  /// 通过 state 变化触发 UI rebuild:StateNotifier 实例字段不会自动通知 listener,
  /// 必须写回 state。
  void setPendingQuote(Quote q) {
    state = state.copyWith(pendingQuote: q);
  }

  /// 清空待发送引用(用户点「取消引用」按钮 / 发送完成后调用)。
  void clearPendingQuote() {
    if (state.pendingQuote == null) return;
    state = state.copyWith(clearPendingQuote: true);
  }

  Future<void> sendText(String text) async {
    final mode = state.modeOverride;
    final data = <String, dynamic>{'text': text};
    if (mode != null) data['_mode'] = mode;
    final model = _effectiveModel;
    if (model != null) {
      data['_model'] = {
        'provider_id': model.providerID,
        'model_id': model.modelID,
      };
    }
    final content = <String, dynamic>{
      'msg_type': MsgType.text.value,
      'data': data,
    };
    _mergePendingQuote(content);
    final localId = 'local_${DateTime.now().microsecondsSinceEpoch}';
    debugPrint(
      '[debug-send] sendText localId=$localId '
      'displayMessages before=${state.displayMessages.length} '
      'isInitialLoading=${state.isInitialLoading}',
    );
    _appendOptimisticMessage(content: content, localId: localId);
    try {
      final result = await api.sendMessage(conversationId, content);
      debugPrint(
        '[debug-send] sendText API done localId=$localId '
        'serverId=${result.messageId}',
      );
      _replaceLocalWithServerId(
        localId,
        serverId: result.messageId,
        serverCreatedAt: result.createdAt,
      );
    } catch (e) {
      debugPrint('[debug-send] sendText FAILED localId=$localId: $e');
      _markFailed(localId);
    }
    // 发送完成(成功或失败)后清空 pendingQuote。
    // 失败也清:用户重发不会带原来的引用,避免重复引用;若需重发引用可重新设置。
    if (state.pendingQuote != null) {
      state = state.copyWith(clearPendingQuote: true);
    }
  }

  /// 发送斜杠命令(用户在命令面板选中后触发)。
  ///
  /// 与 [sendText] 互斥:不发普通 text,content.data 只带 `_slash` 字段,
  /// server/plugin 端识别 `_slash` 后调对应命令而非走 LLM。
  /// 本地乐观消息用 [MsgType.slashEcho] 类型(独立 renderer 渲染 `▶ /name · args`),
  /// 让用户瞬间看到「我刚才触发了 /xxx」的反馈。
  /// 失败兜底同 sendText(走 [_markFailed])。
  Future<void> sendSlash(String name, String args) async {
    final display = args.isEmpty ? '▶ /$name' : '▶ /$name · $args';
    final data = <String, dynamic>{
      'text': '',
      '_slash': {'name': name, 'args': args},
      'display': display,
    };
    // _model 透传(对称 sendText):compact 等命令需要 model 信息,
    // plugin engine 在 _slash 分支内按需读取。
    // 读 _effectiveModel 而非 state.modelOverride:OC 优先策略会把已被 server
    // 采纳的 override 清空,此时靠 sessionMeta 兜底——否则 compact 触发时
    // _model 缺失,plugin engine fail-fast "compact 命令缺少 _model 字段"。
    final model = _effectiveModel;
    if (model != null) {
      data['_model'] = {
        'provider_id': model.providerID,
        'model_id': model.modelID,
      };
    }
    final content = <String, dynamic>{
      'msg_type': MsgType.slashEcho.value,
      'data': data,
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
      debugPrint('[debug-send] sendSlash FAILED localId=$localId: $e');
      _markFailed(localId);
    }
  }

  /// 把 state.pendingQuote 合并到 content.data.quote。
  ///
  /// 写**完整 snapshot**(message_id + sender_*  + msg_type + preview),
  /// 让本地乐观消息引用块内容立即正确呈现(sender 行 + preview 行可见),
  /// 不必等 server echo。server 端 enrichQuote 仍会用权威值覆盖 quote 全部字段
  /// (查 quoted_msg + senderDisplayName + extractPreview 重新构造),所以 client
  /// 传啥字段都不影响协议安全性,只是借 content 把 snapshot 同步给本地渲染层。
  ///
  /// 无 pendingQuote 时是 no-op。quote 字段在构造 content 时一次性写入,后续不
  /// 通过 copyWith 改(Task 7 reviewer 注:ChatMessage.copyWith(quote:...) 语义模糊,
  /// null 会被 fallback 拦截无法显式清空)。
  void _mergePendingQuote(Map<String, dynamic> content) {
    final q = state.pendingQuote;
    if (q == null) return;
    final data = content['data'] as Map<String, dynamic>;
    data['quote'] = q.toJson();
  }

  Future<void> sendFile(String fileId, MsgType msgType,
      {String filename = '',
      String mimeType = '',
      int fileSize = 0}) async {
    final content = {
      'msg_type': msgType.value,
      'data': {
        'file_id': fileId,
        if (filename.isNotEmpty) 'filename': filename,
        if (mimeType.isNotEmpty) 'mime_type': mimeType,
        if (fileSize > 0) 'file_size': fileSize,
      },
    };
    _mergePendingQuote(content);
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
    // 发送完成(成功或失败)后清空 pendingQuote。
    // 失败也清:用户重发不会带原来的引用,避免重复引用;若需重发引用可重新设置。
    if (state.pendingQuote != null) {
      state = state.copyWith(clearPendingQuote: true);
    }
  }

  /// 重试失败的发送消息。点击失败气泡的重试按钮时调。
  ///
  /// 流程:找失败消息 → 切回 sending → 调 api.sendMessage →
  /// 成功替换 id + 切 sent;失败再切 failed。
  Future<void> retrySend(String failedLocalId) async {
    // 双 list 查找失败消息
    final liveIdx = state.liveMessages.indexWhere((m) => m.id == failedLocalId);
    final histIdx =
        state.historyMessages.indexWhere((m) => m.id == failedLocalId);
    final msg = liveIdx >= 0
        ? state.liveMessages[liveIdx]
        : (histIdx >= 0 ? state.historyMessages[histIdx] : null);
    if (msg == null) return;
    if (msg.status != MessageStatus.failed) return;

    // 切回 sending
    state = _updateMessageById(
        failedLocalId, (m) => m.copyWith(status: MessageStatus.sending));
    // F4: 同步把 DB 中该消息切回 sending,保证重入会话看到 sending 态。
    if (store != null) {
      store!.updateStatus(failedLocalId, MessageStatus.sending).catchError((e) {
        debugPrint('[localdb] retrySend updateStatus fail: $e');
      });
    }

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
    state = _removeMessageByIds({localId});
  }

  /// 发送方乐观更新：本地立即插入一条临时消息让 UI 即时显示。
  ///
  /// **id 用 local_ 前缀**：避免跟 server 生成的 UUID 冲突。HTTP 成功后调
  /// _replaceLocalWithServerId 替换为 server 真值。
  /// **sender_id 用真实 currentUserId**：isMe 判断走 senderId == currentUserId,
  /// 必须用真实 id 才能让乐观消息显示在右侧(自己侧)。
  /// **status=sending**:气泡外侧显示 loading,server 返回后切 sent 或 failed。
  ///
  /// F4: store != null 时同步把 tempMsg 写 DB(失败 silently,DB 加速层不阻塞 UI)。
  /// 不 await:tempMsg 已入 state,DB 写在后台进行,调用方 fire-and-forget。
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
      // 乐观消息本地立即呈现引用块(发送方瞬间也能看到上方引用),
      // 重入会话走 fromJson 时会重新解析覆盖,语义一致。
      quote: parseQuote(content),
      isRead: true,
      // 乐观消息立即显示头像(避免 sending 状态字母色块 fallback);
      // currentUser 为 null(测试环境)时退化为字母色块,功能不阻塞。
      senderName: currentUser?.displayName,
      senderAvatarUrl: currentUser?.avatarUrl,
      createdAt: DateTime.now(),
      status: MessageStatus.sending,
    );
    debugPrint(
      '[debug-optimistic] PUSH localId=$localId '
      'liveMessages ${state.liveMessages.length}→${state.liveMessages.length + 1} '
      'senderName=${currentUser?.displayName} '
      'hasAvatar=${currentUser?.avatarUrl != null}',
    );
    state = state.copyWith(
      liveMessages:
          _insertLiveKeepingStreamingLast(state.liveMessages, tempMsg),
    );
    if (store != null) {
      // fire-and-forget:避免 sendText/sendFile 链路变长,DB 写失败不影响 UI。
      store!.putMessage(tempMsg).catchError((e) {
        debugPrint('[localdb] _appendOptimisticMessage fail: $e');
      });
    }
  }

  /// HTTP 发送成功后,把本地 local_xxx id 替换为 server 真值。
  /// 同步切 status=sent,server echo 后续到达时按 server id 去重(命中现有 _onMessageCreate)。
  ///
  /// F4: store != null 时同步替换 DB 中 local_ 行为 server_ 行
  /// (replaceLocalWithServer 单事务原子,避免半态)。
  void _replaceLocalWithServerId(
    String localId, {
    required String serverId,
    required DateTime serverCreatedAt,
  }) {
    final before = state.liveMessages.isEmpty
        ? "live=empty hist=${state.historyMessages.length}"
        : "live=${state.liveMessages.length} last=${state.liveMessages.last.id}";
    debugPrint(
      '[debug-replaceId] $localId → $serverId (serverCreatedAt=$serverCreatedAt) '
      'before=$before',
    );
    state = _updateMessageById(localId, (m) => m.copyWith(
      id: serverId,
      createdAt: serverCreatedAt,
      status: MessageStatus.sent,
    ));
    final inLive = state.liveMessages.where((m) => m.id == serverId).length;
    final inHist =
        state.historyMessages.where((m) => m.id == serverId).length;
    debugPrint(
      '[debug-replaceId] after update: server $serverId inLive=$inLive inHist=$inHist',
    );
    if (store != null) {
      // C1: 此处 fire-and-forget 假设 putMessage(tempMsg) 已 commit,
      // 否则 replaceLocalWithServer select 找不到 localId 行,replace 会是 no-op,
      // DB 残留 local_xxx 行 + 新插 server 行(双重消息)。
      // 实际依赖:
      // 1) drift NativeDatabase.createInBackground 是 isolate 串行处理,操作按序执行;
      // 2) sendText/sendFile 内部 await api.sendMessage() 网络往返给了 putMessage
      //    充足时间完成(网络是毫秒级,DB 写入微秒级)。
      // 极端场景(网络极快 + DB 卡顿)理论可能 race,但生产环境概率极低。
      // 如真触发,_initialize 重拉会校正(putMessages insertOrReplace 幂等,
      // server 行覆盖 local_xxx;但 local_xxx 行残留,DB 多一行,影响 DB-only 呈现)。
      store!.replaceLocalWithServer(localId, serverId, serverCreatedAt)
          .catchError((e) {
        debugPrint('[localdb] replaceLocalWithServer fail: $e');
      });
    }
  }

  /// HTTP 发送失败,切 status=failed。气泡外侧重试按钮。
  ///
  /// F4: store != null 时同步把 DB 中该消息切 status=failed,
  /// 让重入会话能看到失败气泡(而不是丢消息)。
  void _markFailed(String localId) {
    state = _updateMessageById(
        localId, (m) => m.copyWith(status: MessageStatus.failed));
    if (store != null) {
      store!.updateStatus(localId, MessageStatus.failed).catchError((e) {
        debugPrint('[localdb] _markFailed fail: $e');
      });
    }
  }

  /// 删除/撤回消息。
  /// scope='hide' (默认):对自己隐藏,乐观本地移除。
  /// scope='recall':撤回,乐观本地切 recalled 态(占位提示),server 确认后广播切全员。
  ///
  /// F4: store != null 时同步把变更落 DB,
  /// - hide: store.deleteMessage 删行
  /// - recall: store.markRecalled 切 recalled 态(占位保留)
  /// 失败 silently;server 调失败时 catch 走 _initialize 重新拉,DB 校正一致。
  ///
  /// C2 修复:hide 分支失败回滚。原实现 catch 直接调 _initialize 重拉,
  /// 但 server 没真删,_initialize 的 server 返回仍含被删消息,会重新写 DB + state,
  /// 用户体感「删除失败消息复活」。修复:catch 时把乐观删的 removed 塞回 state + putMessages,
  /// 再走 _initialize(此时 server 仍有这些消息,putMessages 幂等,用户看到「未删除」是预期)。
  Future<void> deleteMessages(List<String> ids, {String scope = 'hide'}) async {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    // hide 分支记录乐观删除前的消息(按 list 区分),server 失败时按原 list 回滚
    // (避免把原 live 消息回滚到 history 错位)。recall 分支不回滚。
    List<ChatMessage> removedLive = const [];
    List<ChatMessage> removedHist = const [];
    if (scope == 'recall') {
      // 撤回:乐观本地切 recalled 态(保留消息 id,UI 显示占位)。
      // recalledByName 留空(dispatch 来时填 sender_name)。
      for (final id in idSet) {
        state = _updateMessageById(
            id, (m) => m.copyWith(isRecalled: true, recalledByName: ''));
      }
      if (store != null) {
        for (final id in ids) {
          await store!.markRecalled(id, recalledByName: '');
        }
      }
    } else {
      // hide:乐观本地移除,记录 removed 用于失败回滚(按 list 区分)
      removedLive = state.liveMessages.where((m) => idSet.contains(m.id)).toList();
      removedHist =
          state.historyMessages.where((m) => idSet.contains(m.id)).toList();
      state = _removeMessageByIds(idSet);
      if (store != null) {
        for (final id in ids) {
          await store!.deleteMessage(id);
        }
      }
    }
    try {
      if (ids.length == 1) {
        await api.deleteMessage(ids.first, scope: scope);
      } else {
        await api.batchDeleteMessages(ids);
      }
    } catch (e) {
      // C2 修复:hide 分支失败回滚 state + DB,避免 _initialize 重拉让消息「复活」。
      // recall 分支不回滚(isRecalled 标记保留,server 重拉会校正一致)。
      // 回滚按原 list(live/hist)归位,保持消息在双 sliver 的原始位置。
      if (scope != 'recall' && (removedLive.isNotEmpty || removedHist.isNotEmpty)) {
        final existingIds = {
          ...state.liveMessages.map((m) => m.id),
          ...state.historyMessages.map((m) => m.id),
        };
        final toRestoreLive =
            removedLive.where((m) => !existingIds.contains(m.id)).toList();
        final toRestoreHist =
            removedHist.where((m) => !existingIds.contains(m.id)).toList();
        if (toRestoreLive.isNotEmpty || toRestoreHist.isNotEmpty) {
          state = state.copyWith(
            liveMessages: [...state.liveMessages, ...toRestoreLive],
            historyMessages: [...state.historyMessages, ...toRestoreHist],
          );
          if (store != null) {
            try {
              await store!
                  .putMessages([...toRestoreLive, ...toRestoreHist]);
            } catch (e2) {
              debugPrint('[localdb] deleteMessages rollback putMessages fail: $e2');
            }
          }
        }
      }
      await _initialize();
      rethrow;
    }
  }
}

/// 过滤掉 silent 控制类回复消息（permission_reply / question_reply）。
///
/// 这些消息是 APP→plugin 的控制信号：plugin SyncEngine 拦截后调 OpenCode API，
/// 再 PATCH 原 card 消息切终态。回复消息本身不应在会话列表里渲染成气泡。
/// server 仍会 dispatch MESSAGE_CREATE echo 给 sender（processor.go 注释明确
/// dispatch 含 sender），且 MessageRow 总会渲染头像/占位，故必须在进 state 前
/// 丢弃，否则会冒出空内容 + 头像的垃圾行。history 重载同理（DB 存了回复消息）。
List<ChatMessage> _filterDisplayable(Iterable<ChatMessage> msgs) {
  return msgs.where((m) {
    // 子 agent 事件（parent_msg_id 非空）不在主聊天列表展示。
    // server 端 ListByConversation/ListBefore/ListAfter 已用
    // `WHERE parent_msg_id IS NULL` 过滤；但 local DB 缓存（WS putMessage 无条件存）
    // 仍含子事件，首次 _initialize eager 读取 + loadMore DB 命中时会漏出。
    // 此处补兜底过滤，与 server SQL 行为对齐。
    // 例外:pending 子审批卡放行(在对应 task 卡片下方聚合渲染 ⚡ 缩略条)。
    if (m.parentMsgId != null && m.parentMsgId!.isNotEmpty) {
      if (!m.isPendingChildApproval) return false;
    }
    final t = MsgTypeX.fromString(m.content['msg_type'] as String?);
    // step_finish 分两类:
    // - finished=true 主循环汇总条(plugin part_dispatcher isLoopEnd 发,silent=false
    //   计未读 + 响铃):StepFinishRenderer 渲染 tokens 小字,也是未读定位锚点,必须放行,
    //   否则 server FirstUnread 返回它而列表里找不到 → 定位 ABORT(锚点悬空)。
    // - finished 缺失中间推理步(silent=true 过程元数据):app 不展示,过滤。
    return t != MsgType.permissionReply &&
        t != MsgType.questionReply &&
        !(t == MsgType.stepFinish && !_isMainLoopStepFinish(m.content));
  }).toList();
}

/// step_finish 是否主循环结束汇总条(finished=true,plugin part_dispatcher 的 isLoopEnd)。
/// 主循环结束:渲染 tokens 小字 + 作为未读定位锚点;中间推理步:过滤。
bool _isMainLoopStepFinish(Map<String, dynamic> content) {
  final data = content['data'];
  if (data is! Map) return false;
  return data['finished'] == true;
}

bool _isPendingChildApprovalCard(Map<String, dynamic> msgData) {
  if (msgData['parent_msg_id'] == null) return false;
  final content = msgData['content'] as Map<String, dynamic>?;
  if (content == null) return false;
  final mt = content['msg_type'] as String?;
  if (mt != 'permission_card' && mt != 'question_card') return false;
  final status = (content['data'] as Map<String, dynamic>?)?['status'];
  return status == 'pending';
}

final wsProvider = Provider<WebSocketService>((ref) {
  // 只订阅 token 字段：updateProfile 等会刷新 state.user，若 watch 整个 AuthState
  // 会触发 WS 重建并断连。token 不变时 WS 保持连接。
  final token = ref.watch(authProvider.select((s) => s.token));
  final baseUrl = ref.watch(settingsProvider);
  final storeAsync = ref.watch(localMessageStoreProvider);

  // I2 修复:store loading 态等下次 rebuild(provider 会因 watch 自动 rebuild),
  // 避免在 store=null 时 connect 导致 Resume last_seq=null 丢消息。
  // 场景:用户登录后短暂未进 ChatPage,store autoDispose 释放;token refresh
  // 触发 wsProvider rebuild,此时 storeAsync 是 AsyncLoading,store=null,
  // 若直接 connect 会走 hello 分支 Resume last_seq=null,断线期间消息全丢。
  if (storeAsync.isLoading) {
    final ws = WebSocketService();
    ref.onDispose(() => ws.disconnect());
    return ws;
  }

  // F4: 注入 LocalMessageStore(可空)。store ready 前先传 null,hello 分支
  // Resume last_seq 走内存兜底(_lastSeq);main.dart 启动序列已 await
  // localMessageStoreProvider.future,正常路径下 store 在 ws connect 前就 ready。
  final store = storeAsync.maybeWhen(
    data: (s) => s,
    orElse: () => null,
  );
  final ws = WebSocketService(store: store);
  // tokenRefresher:WS 重连前调用,处理 token 过期但无 API 401 触发 refresh 的场景。
  // apiProvider 是 Provider,ref.read 拿当前实例(不订阅重建)。
  // 返回 null 表示无法刷新,WS 用旧 token 重试(靠 backoff 兜底)。
  ws.tokenRefresher = () => ref.read(apiProvider).tryRefreshToken();
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

/// 本地存储健康状态流。true=degraded(连续失败超阈值)。
/// UI 订阅后显示「本地存储异常」提示,让用户感知消息可能没持久化。
/// 跟随 wsProvider 重建(对齐 connStateProvider 行为)。
final localStoreHealthProvider = StreamProvider<bool>((ref) {
  final ws = ref.watch(wsProvider);
  return ws.localStoreHealthStream;
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
  // F4: 用 select(valueOrNull) 让 chatProvider 跟随 store 异步 ready 重建以注入 store 实例。
  // select 取 AsyncValue.valueOrNull:store 在 loading/error 态时为 null,ready(data) 后变为实例。
  // valueOrNull 变化(null → 实例)触发 chatProvider 重建,把 store 注入 ChatNotifier。
  // 这样:
  // 1. 测试环境 authProvider 未登录 → store FutureProvider 进 error → valueOrNull 保持 null,
  //    不会因 AsyncLoading→AsyncError 这种内部状态切换而误触 chatProvider 重建
  //    (旧 ChatNotifier 在 _initialize 异步执行中被 dispose)
  // 2. 生产环境 store 在 main.dart 已 await ready,首次构建时 valueOrNull 就是实例。
  final store = ref.watch(
      localMessageStoreProvider.select((async) => async.valueOrNull));
  return ChatNotifier(
    ref.watch(apiProvider),
    ref.watch(wsProvider),
    key.convId,
    key.agentId,
    ref.watch(authProvider.select((s) => s.user?.id ?? '')),
    store: store,
    currentUser: ref.watch(authProvider.select((s) => s.user)),
  );
});
