import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting, debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../models/conversation.dart';
import '../models/participant.dart';
import '../models/ws_message.dart';
import '../services/api_service.dart';
import '../services/local_message_store_abstract.dart';
import '../services/noop_local_message_store.dart';
import '../services/websocket_service.dart';
import '../utils/diff_merge.dart';
// 复用现有 provider，避免重复定义导致状态分裂。
import 'auth_provider.dart' show apiProvider, authProvider;
import 'chat_provider.dart' show wsProvider;
import 'local_message_store_provider.dart' show localMessageStoreProvider;

/// 会话列表状态管理：负责拉取会话列表，并订阅 WebSocket MESSAGE_CREATE 事件，
/// 在本地更新最近一条消息预览并把对应会话置顶。
class ConversationListNotifier extends StateNotifier<List<Conversation>> {
  final ApiService api;
  final WebSocketService ws;
  /// 当前 user.id。用于 _onMessageCreate 判断「自己发的消息不计未读」。
  /// participants 模型下 sender 可能是 user 也可能是 agent,只要不是自己发的就算未读。
  final String currentUserId;
  /// F5: 本地缓存 store。cache-first 加载 + WS 关键事件 fire-and-forget 落库。
  /// store 加载中 / 失败时由 Provider 注入 NoopLocalMessageStore 占位,
  /// 此时 provider 退化成纯 API 模式(向后兼容)。
  final LocalMessageStore _store;
  StreamSubscription<WSMessage>? _subscription;
  StreamSubscription<WSMessage>? _conversationEventsSub;
  StreamSubscription<WSMessage>? _messageReadSub;
  StreamSubscription<WSMessage>? _messageUpdateSub;
  Timer? _pendingReloadTimer;
  // 当前打开的 ChatPage convId。该会话收到的 agent 消息不计未读（用户正在看）。
  String? _activeConvId;

  ConversationListNotifier(
    this.api,
    this.ws,
    this.currentUserId,
    this._store, {
    bool autoload = true,
  }) : super([]) {
    // 构造即拉取:切换账号时 apiProvider/wsProvider 重建会连带重建本 notifier,
    // 新 server 的历史会话需要重新拉。messages_page 用 AutomaticKeepAlive 保活,
    // 切换时不会重建触发 initState 的 load,故此处主动 load 兜底。
    // 与 agentListProvider 构造即 load 的模式对齐。
    // autoload=false 仅供单元测试:直接构造 Notifier 测 pin/resort 等纯逻辑时,
    // 跳过 load 避免触发未 stub 的 getConversations。
    if (autoload) load();
    _subscription = ws.messages
        .where((m) => m.t == 'MESSAGE_CREATE' || m.t == 'MESSAGE_DELETE')
        .listen((m) {
      if (m.t == 'MESSAGE_DELETE') {
        // 删除可能改变 last_message_content(删的是最后一条时),
        // 直接 load 重拉列表最简单可靠(无需本地猜测新缓存)。
        load();
        return;
      }
      _onMessageCreate(m);
    });
    // 订阅 N 方 participants 模型的会话管理事件
    _conversationEventsSub = ws.conversationUpdates.listen((m) {
      switch (m.t) {
        case 'CONVERSATION_PARTICIPANT_JOIN':
          _onParticipantJoin(m);
          break;
        case 'CONVERSATION_PARTICIPANT_LEAVE':
          _onParticipantLeave(m);
          break;
        case 'CONVERSATION_UPDATE':
          _onConversationUpdate(m);
          break;
      }
    });
    // 多端同步:其他端 markRead 后,server 推 MESSAGE_READ 给本端,
    // 立即刷本地 unreadCount(不等下拉刷新)。
    _messageReadSub = ws.messageReads.listen((m) {
      final d = m.d as Map<String, dynamic>?;
      if (d == null) return;
      final convId = d['conversation_id'] as String?;
      if (convId == null) return;
      final newUnread = (d['unread_count'] as num?)?.toInt() ?? 0;
      debugPrint(
        '[debug-ws-read] MESSAGE_READ convId=$convId newUnread=$newUnread '
        'state has conv? ${state.indexWhere((c) => c.id == convId) >= 0} '
        'state entries=${state.map((c) => c.id.length >= 8 ? '${c.id.substring(0, 8)}...' : c.id).join(',')}',
      );
      setUnreadCountLocally(convId, newUnread);
    });
    _messageUpdateSub = ws.messageUpdates.listen(_onMessageUpdate);
  }

  void _onMessageUpdate(WSMessage m) {
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conversation_id'] as String?;
    if (convId == null) return;
    final content = data['content'] as Map<String, dynamic>?;
    final msgType = content?['msg_type'] as String?;
    if (msgType == 'permission_card' || msgType == 'question_card') {
      _pendingReloadTimer?.cancel();
      _pendingReloadTimer = Timer(const Duration(milliseconds: 200), load);
      return;
    }
    // 聚合卡回合结束翻转:silent true→false → 徽章+1 + 更新预览 + 置顶排序。
    // generating 阶段(silent 仍 true)的 MESSAGE_UPDATE 只更新渲染(chatProvider),列表不动。
    if (content != null &&
        msgType == 'aggregate_card' &&
        content['silent'] == false) {
      _onAggregateCardFlip(convId, content);
    }
  }

  /// 聚合卡回合结束(silent true→false)翻转:徽章+1 + lastMessageContent 更新为
  /// 聚合卡 content(预览经 [Conversation.lastMessagePreview] → MsgTypeX.preview
  /// 取最后 markdown 元素 text)+ 置顶排序。
  ///
  /// 会话不在列表时跳过:由 load()/下一次拉取兜底(server 已在翻转时 IncrUnread,
  /// ListForUser 的 last_message_content 也是翻转后的聚合卡)。
  void _onAggregateCardFlip(String convId, Map<String, dynamic> content) {
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final item = state[idx];
    // 与 _onMessageCreate 同口径:正在看该会话时不 +1(本地徽章 UX 优化,
    // server 端已计未读,进会话时 markRead 归零)。
    final isActive = convId == _activeConvId;
    final newItem = item.copyWith(
      lastMessageContent: content,
      unreadCount: isActive ? item.unreadCount : item.unreadCount + 1,
    );
    state = [...state.where((c) => c.id != convId), newItem];
    _resort();

    // F5: 关键事件 fire-and-forget 落库
    _persistConv(newItem, tag: 'MESSAGE_UPDATE_AGGREGATE_FLIP');
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _conversationEventsSub?.cancel();
    _messageReadSub?.cancel();
    _messageUpdateSub?.cancel();
    _pendingReloadTimer?.cancel();
    super.dispose();
  }

  /// ChatPage 进入/离开时切换激活会话。激活期间 incoming 消息不计未读。
  /// 同时同步给后台 service isolate，用于本地通知过滤：
  /// 前台且正在看该会话时不弹通知（用户已直接看到）。
  void setActiveConv(String? convId) {
    _activeConvId = convId;
    // 同步给 bg-service。原生平台未注册时 invoke 可能抛异常（测试环境），
    // 不应影响主流程，吞掉即可。
    try {
      FlutterBackgroundService().invoke('setActiveConv', {
        'conv_id': convId ?? '',
      });
    } catch (_) {
      // 测试环境无原生平台注册，忽略
    }
  }

  /// F5 fix helper: 单条 fire-and-forget 落库。
  /// 用于所有改 state 的方法(markReadLocally / pin / unpin / createGroup 等)
  /// 同步 store,防止下次 cache-first load 用旧 store 覆盖刚改的 state。
  /// 不阻塞主流程,失败 debugPrint。
  void _persistConv(Conversation conv, {required String tag}) {
    _store.putConversation(currentUserId, conv).catchError(
      (e) => debugPrint('[conv] putConversation($tag) fail: $e'),
    );
  }

  /// F5 fix helper: 整列表 fire-and-forget 落库。
  /// 用于 hide / leaveConversation / removeByAgentId 等移除会话的场景
  /// (单条 putConversation 无法表达删除,只能整列表覆盖)。
  void _persistList({required String tag}) {
    _store.putConversations(currentUserId, state).catchError(
      (e) => debugPrint('[conv] putConversations($tag) fail: $e'),
    );
  }

  /// 拉取会话列表(F5: cache-first + diff-merge + 落库)。
  ///
  /// 流程:
  /// 1. await store.getConversations(uid) 立即返回 cached → state=cached
  /// 2. 后台 api.getConversations() → diff-merge 字段级合并 → state=merged
  /// 3. fire-and-forget 写库
  /// 4. 失败静默(state 已是 cached, ConnBanner 由 connState 决定)
  Future<void> load() async {
    // F5: cache-first
    List<Conversation> cached;
    try {
      cached = await _store.getConversations(currentUserId);
      // 过滤 agent_session:server ListForUser SQL 硬过滤 c.type != 'agent_session',
      // 本地缓存需对齐此行为。chat_provider 写回的 agent_session 单条缓存不应进入列表。
      cached = cached.where((c) => c.type != 'agent_session').toList();
    } catch (e) {
      debugPrint('[conv] store.getConversations fail: $e');
      cached = [];
    }
    if (!mounted) return;
    // cache-first 只在 state 为空(首次加载 / 切换账号 provider 重建)时覆盖。
    // state 已有数据时(下拉刷新 / 退群后刷新),cached 可能因 _persistList
    // fire-and-forget 滞后写入而陈旧,覆盖会让 UI 闪现已移除的会话
    // (leaveConversation / hide / removeByAgentId 场景)。
    if (cached.isNotEmpty && state.isEmpty) state = cached;

    // 后台 API 刷新
    try {
      final fresh = await api.getConversations();
      if (!mounted) return;

      // 空列表保护: server 异常返空时不覆盖本地
      if (fresh.isEmpty && cached.isNotEmpty) {
        syncAgentAvatarsToBgService(state);
        return;
      }

      // F5: diff-merge 字段级
      final merged = diffMerge(
        localList: state,
        freshList: fresh,
        idOf: (c) => c.id,
        mergeItem: (local, f) => _mergeConversation(local, f),
        keepLocal: (_) => false,
      );
      // F5: active 兜底第二道(diffMerge 后扫一遍)。
      // 必要性:diffMerge 算法在 local 不存在该 id 时直接用 fresh 整对象,
      // 跳过 mergeItem 调用,导致 _mergeConversation 内的 active 强制 0 规则失效。
      // 此处对最终 merged 列表再扫一遍,把 active conv 的 unreadCount 强制 0,
      // 确保"用户正在看的会话徽章必须为 0"不变量在 fresh-only 场景也成立。
      // 性能:state 通常 < 100 条,O(n) 扫一遍无压力。
      final finalized = _activeConvId == null
          ? merged
          : [
              for (final c in merged)
                c.id == _activeConvId ? c.copyWith(unreadCount: 0) : c,
            ];
      state = finalized;

      // fire-and-forget 落库
      _store.putConversations(currentUserId, finalized).catchError(
        (e) => debugPrint('[conv] store.putConversations fail: $e'),
      );

      syncAgentAvatarsToBgService(state);
    } catch (e) {
      // REST 失败静默: state 已是 cached, ConnBanner 由 connState 决定
      debugPrint('[conv] api.getConversations fail: $e');
    }
  }

  /// Conversation 字段级 merge: server 字段用 fresh, client-only 字段保留本地。
  ///
  /// unreadCount 合并规则:
  /// - active 强制 0(用户正在看的会话,徽章必须为 0,否则闪屏)
  /// - 其他直接用 fresh(server 真值)
  ///
  /// 不再用 max(local, fresh):processor.go 的 dispatch 在 commit 之后,
  /// server 的 IncrUnread 已经在 fresh 里,本地 +1 是冗余 optimistic 更新。
  /// max 逻辑在跨设备同步场景下反向 — A 设备已读后 server unread=0,
  /// B 设备 local 还是旧的 N,max(5,0)=5 导致下拉刷新都不更新。
  Conversation _mergeConversation(Conversation local, Conversation fresh) {
    final isActive = fresh.id == _activeConvId;
    final unread = isActive ? 0 : fresh.unreadCount;
    return fresh.copyWith(unreadCount: unread);
  }

  void _onMessageCreate(WSMessage m) {
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conversation_id'] as String?;
    if (convId == null) return;

    final senderId = data['sender_id'] as String?;
    // participants 模型下 sender 可能是 user 也可能是 agent,
    // 只要不是自己发的就算未读(覆盖 user-user / agent→user / 群聊场景)。
    final isOwn = senderId == currentUserId;

    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) {
      // 不在列表里：可能是首次给该 agent 发消息（conv 还没 load 过），
      // 或 user 一直没进过消息 tab。触发 load 把最新列表拉回来。
      load();
      return;
    }

    final content = data['content'] as Map<String, dynamic>?;
    final item = state[idx];

    final createdAtStr = data['created_at'] as String?;
    final lastMessageAt = createdAtStr != null
        ? DateTime.parse(createdAtStr)
        : item.lastMessageAt;

    // silent 消息不计未读（与 server IncrUnreadTx + bg-service 完全对齐）。
    // silent=true 表示过程类消息（AI 思考、工具调用、step_finish 等）,
    // server processor.go 在 IncrUnreadTx 前已据此跳过,APP 三路计数也必须对齐,
    // 否则会出现「server unread=0 但 APP 徽章=N」的不一致。
    final isSilent = content?['silent'] == true;

    // 非自己发的消息且不在该会话页时本地 unreadCount++。
    // 但若用户当前正在该会话（_activeConvId），本地不计未读 —— 避免用户在看的
    // 会话还闪烁徽章。server 端已不再据此跳过 IncrUnread（一律计未读,client 端
    // _markRead 归零）,此处的本地判断纯属徽章 UX 优化。
    final isActive = convId == _activeConvId;
    final newUnread = (!isOwn && !isActive && !isSilent)
        ? item.unreadCount + 1
        : item.unreadCount;

    // 摘要守卫:silent 消息 或 step_finish 不更新 lastMessageContent。
    // - silent=true:过程类消息不应污染会话列表预览（与 lastMessagePreview
    //   对 permission_reply/question_reply 返 '' 同口径）。
    // - step_finish:streamer 主 session idle 时发的「会话结束」标记,
    //   plugin 用它响铃 + 计未读（silent=false）,但内容只是 {duration} 无预览价值,
    //   不应覆盖上一条真实对话的摘要。
    final msgType = content?['msg_type'] as String? ?? 'text';
    final shouldUpdatePreview = !isSilent && msgType != 'step_finish';

    // copyWith 保留 isPinned 等其它字段；直接 Conversation(...) 会丢 isPinned
    // 导致置顶背景色被刷掉。
    final newItem = item.copyWith(
      lastMessageContent:
          shouldUpdatePreview ? content : item.lastMessageContent,
      lastMessageAt: lastMessageAt,
      unreadCount: newUnread,
    );
    // 用 _resort 重排：置顶组在前，组内按 lastMessageAt 倒序。
    // 直接 prepend 会破坏置顶/非置顶分组。
    state = [...state.where((c) => c.id != convId), newItem];
    _resort();

    // F5: 关键事件 fire-and-forget 落库
    _persistConv(newItem, tag: 'MESSAGE_CREATE');
  }

  /// ChatPage 进入时调：本地立即清零该会话 unread（服务端由 markConversationRead API 清）。
  /// 立即清零避免 badge 滞留到下次 list 刷新。
  void markReadLocally(String convId) {
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final old = state[idx];
    if (old.unreadCount == 0) return;
    final updated = List<Conversation>.from(state);
    // copyWith 保留 isPinned 等其它字段；直接 Conversation(...) 会丢 isPinned
    // 导致置顶背景色被刷掉。
    updated[idx] = old.copyWith(unreadCount: 0);
    state = updated;
    // F5 fix: 同步刷 store, 防止下次 cache-first load 用旧 unread 覆盖刚清的 0。
    _persistConv(updated[idx], tag: 'markReadLocally');
  }

  /// 按 server 返回的精确值更新本地 unread（不是简单清零）。
  /// 用于 markMessagesRead API 同步：server 重算后的 unread_count 反映真实剩余未读，
  /// 直接覆写本地值让会话列表徽章立即对齐。
  void setUnreadCountLocally(String convId, int newUnread) {
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final old = state[idx];
    if (old.unreadCount == newUnread) return;
    final updated = List<Conversation>.from(state);
    updated[idx] = old.copyWith(unreadCount: newUnread);
    state = updated;
    _persistConv(updated[idx], tag: 'setUnreadCountLocally');
  }

  /// 会话内收到 agent 新消息时 +1 本地 unread（与 chatProvider 浮标保持一致）。
  ///
  /// conversationProvider 内置的 _onMessageCreate 在 isActive=true 时不 +1
  /// （本地 UX 优化:避免用户在看的会话还显示徽章）。但 chatProvider 浮标会 +1
  /// （让用户感知到新消息）,导致两端不一致。本方法供 ChatPage ref.listen (2)
  /// 分支同步两端使用。
  ///
  /// 注:server 端已不再据此跳过 IncrUnread（所有 agent 消息一律计未读）,
  /// 此处的 isActive 判断纯属本地徽章 UX 优化,不影响 server unread_count。
  void incrementUnreadLocally(String convId) {
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final old = state[idx];
    final updated = List<Conversation>.from(state);
    updated[idx] = old.copyWith(unreadCount: old.unreadCount + 1);
    state = updated;
    _persistConv(updated[idx], tag: 'incrementUnreadLocally');
  }

  void removeByAgentId(String agentId) {
    // dm_user_user / 群聊的 agent=null（agentId != null 必然 != null → true，保留）。
    state = state.where((c) => c.agent?.id != agentId).toList();
    _persistList(tag: 'removeByAgentId');
  }

  void upsert(Conversation conv) {
    final idx = state.indexWhere((c) => c.id == conv.id);
    if (idx == -1) {
      state = [conv, ...state];
    } else {
      final updated = List<Conversation>.from(state);
      updated[idx] = conv;
      state = updated;
    }
    _persistConv(conv, tag: 'upsert');
  }

  /// 置顶会话。调 API + 本地乐观更新 + resort。
  Future<void> pin(String convId) async {
    await api.pinConversation(convId);
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    state = List<Conversation>.from(state)
      ..[idx] = state[idx].copyWith(isPinned: true);
    _resort();
    _persistConv(state[idx], tag: 'pin');
  }

  /// 取消置顶。
  Future<void> unpin(String convId) async {
    await api.unpinConversation(convId);
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    state = List<Conversation>.from(state)
      ..[idx] = state[idx].copyWith(isPinned: false);
    _resort();
    _persistConv(state[idx], tag: 'unpin');
  }

  /// 软删除会话。调 API + 本地移除。
  Future<void> hide(String convId) async {
    await api.hideConversation(convId);
    state = state.where((c) => c.id != convId).toList();
    _persistList(tag: 'hide');
  }

  // === N 方 participants 模型:群管理方法 ===

  /// 创建群聊(type=group_user 默认;群成员从好友列表选 username)。
  /// 成功后返回新会话 ID(供调用方 push 到 ChatPage)。
  ///
  /// 入参用 username(spec §4.2:client 不持 user_id 防枚举,server 端反查)。
  Future<String> createGroup({
    required List<String> memberUsernames,
    String? title,
    String? avatarUrl,
  }) async {
    final conv = await api.createConversation(
      type: 'group_user',
      memberUsernames: memberUsernames,
      title: title,
      avatarUrl: avatarUrl,
    );
    // 乐观本地插入(创建者是 owner,自动加为 participant 由 server 处理)
    state = [conv, ...state];
    _resort();
    _persistConv(conv, tag: 'createGroup');
    return conv.id;
  }

  /// 邀请成员加入会话。
  /// server 会广播 CONVERSATION_PARTICIPANT_JOIN,本地通过订阅自动更新。
  Future<void> inviteMember(
      String convId, String memberId, String memberType) async {
    await api.inviteMember(convId, memberId, memberType);
    // 不做本地乐观更新,等 server 广播 JOIN 事件触发 _onParticipantJoin
  }

  /// 退群 / 销群。
  /// 普通成员退群:本地从 list 移除自己(自身 participant 行被删)。
  /// owner 退群 → 销群:整个会话从 list 消失。
  Future<void> leaveConversation(String convId) async {
    await api.leaveConversation(convId);
    state = state.where((c) => c.id != convId).toList();
    _persistList(tag: 'leaveConversation');
  }

  /// 更新群名 / 群头像(仅 owner / admin 可调,server 校验)。
  /// server 会广播 CONVERSATION_UPDATE,本地通过订阅自动更新。
  Future<void> updateGroupProfile(String convId,
      {String? title, String? avatarUrl}) async {
    await api.updateConversation(convId, title: title, avatarUrl: avatarUrl);
  }

  // === WS 事件订阅:N 方 participants 模型 ===

  /// 处理 CONVERSATION_PARTICIPANT_JOIN 事件。
  /// 本地往该会话 participants 列表加新成员。
  void _onParticipantJoin(WSMessage m) {
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conv_id'] as String?;
    final newMember = data['member_id'] as String?;
    final newMemberType = data['member_type'] as String?;
    final role = data['role'] as String? ?? 'member';
    if (convId == null || newMember == null) return;

    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) {
      // 不在列表(可能是新会话),reload 兜底
      load();
      return;
    }
    final item = state[idx];
    // 若已存在不重复加
    if (item.participants.any((p) =>
        p.memberId == newMember && p.memberType == newMemberType)) return;
    // 简化:新成员的 username/nickname/avatarUrl 未知(server JOIN payload 不带摘要),
    // 用空摘要占位,下次 load 时刷新。
    final newP = Participant(
      memberId: newMember,
      memberType: newMemberType ?? 'user',
      role: role,
      username: '',
      nickname: '',
      avatarUrl: '',
    );
    final updated = List<Conversation>.from(state);
    updated[idx] = item.copyWith(participants: [...item.participants, newP]);
    state = updated;

    // F5: 关键事件 fire-and-forget 落库
    _persistConv(updated[idx], tag: 'PARTICIPANT_JOIN');
  }

  /// 处理 CONVERSATION_PARTICIPANT_LEAVE 事件。
  /// 移除本地 participants 中的成员;若是当前 user 自己,从 list 移除整个会话。
  void _onParticipantLeave(WSMessage m) {
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conv_id'] as String?;
    final memberId = data['member_id'] as String?;
    final memberType = data['member_type'] as String?;
    if (convId == null || memberId == null) return;

    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final item = state[idx];

    // 简化:无法精确知道"当前 user id"(本 provider 不持有 userProvider ref),
    // 由 chat_page / messages_page 等消费方在收到自己的 LEAVE 时主动调
    // hide() 或 leaveConversation() 已经处理了 server 调用,这里只做 participant 列表更新。
    final newParticipants = item.participants
        .where((p) => !(p.memberId == memberId && p.memberType == memberType))
        .toList();
    final updated = List<Conversation>.from(state);
    updated[idx] = item.copyWith(participants: newParticipants);
    state = updated;

    // F5: 关键事件 fire-and-forget 落库
    _persistConv(updated[idx], tag: 'PARTICIPANT_LEAVE');
  }

  /// 处理 CONVERSATION_UPDATE 事件(群名 / 群头像变更)。
  //
  // server BroadcastConversationUpdate 把「未提供」字段填空串,
  // ?? 只在 null 时 fallback 不够,空串也 fallback 才对(否则本地 title 被清空,
  // displayName 走 participants.first 显示「随机成员名」)。
  void _onConversationUpdate(WSMessage m) {
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conv_id'] as String?;
    if (convId == null) return;
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final item = state[idx];
    final newTitle = data['title'] as String?;
    final newAvatar = data['avatar_url'] as String?;
    final updated = List<Conversation>.from(state);
    updated[idx] = item.copyWith(
      title: (newTitle != null && newTitle.isNotEmpty) ? newTitle : item.title,
      avatarUrl: (newAvatar != null && newAvatar.isNotEmpty)
          ? newAvatar
          : item.avatarUrl,
    );
    state = updated;

    // F5: 关键事件 fire-and-forget 落库
    _persistConv(updated[idx], tag: 'CONVERSATION_UPDATE');
  }

  /// 本地排序:置顶组在前,组内按 lastMessageAt 倒序。
  void _resort() {
    state = List<Conversation>.from(state)
      ..sort((a, b) {
        if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
        return b.lastMessageAt.compareTo(a.lastMessageAt);
      });
  }

  /// 测试用:暴露 _resort 供单测调用。
  @visibleForTesting
  void testResort() => _resort();
}

final conversationProvider = StateNotifierProvider<ConversationListNotifier,
    List<Conversation>>((ref) {
  // F5: 用 select 取 valueOrNull, loading/error 时为 null(返 Noop),
  // 仅当 valueOrNull 真正变化(null→store / store→null)时才触发 provider 重建,
  // 避免 FutureProvider 在 loading→error 状态切换时反复重建导致 notifier 抖动。
  final store = ref.watch(localMessageStoreProvider
          .select((async) => async.valueOrNull)) ??
      NoopLocalMessageStore();
  return ConversationListNotifier(
    ref.watch(apiProvider),
    ref.watch(wsProvider),
    ref.watch(authProvider.select((s) => s.user?.id ?? '')),
    store,
  );
});

/// 总未读数。HomePage 消息 tab badge 用。
/// 单独 provider 避免每次 list 变化都重建 HomePage 全部子树。
final totalUnreadProvider = Provider<int>((ref) {
  final list = ref.watch(conversationProvider);
  return list.fold(0, (sum, c) => sum + c.unreadCount);
});

/// 同步所有 agent 的 avatar_url 到 bg-service isolate(供通知下载头像)。
///
/// 在拉会话列表成功后调。原生平台未注册时 invoke 抛异常(测试环境),
/// 用 try-catch 兜底不阻塞 UI。
@visibleForTesting
void syncAgentAvatarsToBgService(List<Conversation> conversations) {
  try {
    final service = FlutterBackgroundService();
    for (final c in conversations) {
      // dm_user_user / 群聊 agent=null，跳过（无 agent 头像可同步）。
      final agentId = c.agent?.id;
      if (agentId == null || agentId.isEmpty) continue;
      service.invoke('syncAgentAvatar', {
        'agentId': agentId,
        'avatarUrl': c.agent!.avatarUrl,
      });
    }
  } catch (_) {
    // 原生平台未注册(测试环境)静默,不阻塞 UI
  }
}
