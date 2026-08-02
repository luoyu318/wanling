import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../models/msg_type.dart';
import '../models/ws_message.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import '../utils/diff_merge.dart';
import 'auth_provider.dart' show apiProvider, authProvider;
import 'chat_provider.dart' show wsProvider;

/// agent session 二级列表状态管理（对齐 conversationProvider 模式）。
///
/// 监听 WS MESSAGE_CREATE / MESSAGE_READ 事件，本地 copyWith 更新
/// last_message + unread（不调 API，0 延迟）。新 session（agent 发消息）
/// 自动 load() 拉入。null state 表示首次加载中。
class AgentSessionsNotifier extends StateNotifier<List<Conversation>?> {
  final ApiService _api;
  final WebSocketService _ws;
  final String _currentUserId;
  final String _agentId;

  StreamSubscription<WSMessage>? _msgSub;
  StreamSubscription<WSMessage>? _readSub;
  StreamSubscription<WSMessage>? _updateSub;
  String? _activeConvId;

  AgentSessionsNotifier(this._api, this._ws, this._currentUserId, this._agentId)
    : super(null) {
    load();
    _msgSub = _ws.messages
        .where((m) => m.t == 'MESSAGE_CREATE')
        .listen(_onMessageCreate);
    _readSub = _ws.messageReads
        .listen(_onMessageRead);
    _updateSub = _ws.messageUpdates.listen(_onMessageUpdate);
  }

  /// 拉取 agent session 列表。state 为 null/空时直接赋值，非空 diffMerge。
  Future<void> load() async {
    try {
      final fresh = await _api.getAgentSessions(_agentId);
      if (!mounted) return;
      final old = state;
      if (old == null || old.isEmpty) {
        state = fresh;
      } else {
        state = diffMerge(
          localList: old,
          freshList: fresh,
          idOf: (c) => c.id,
          mergeItem: (_, f) => f,
          keepLocal: (_) => false,
        );
      }
    } catch (e) {
      debugPrint('[agent-sessions] load fail: $e');
      if (state == null) state = [];
    }
  }

  /// user 主动建 agent_session 群。
  ///
  /// directory: OC session 工作目录,直接透传给 server conversations.directory
  /// 一级列(不再走首条消息 _directory 注入路径)。
  /// 失败向上抛,由调用方(UI)提示用户。
  Future<String> createSession(String agentId, {String? title, String? directory}) async {
    final conv = await _api.createConversation(
      type: 'agent_session',
      memberIds: [agentId],
      memberTypes: const ['agent'],
      title: title,
      directory: directory,
    );
    await load();
    return conv.id;
  }

  void removeLocally(String convId) {
    final current = state;
    if (current == null) return;
    state = current.where((c) => c.id != convId).toList();
  }

  void setActiveConv(String? convId) {
    _activeConvId = convId;
  }

  void _onMessageCreate(WSMessage m) {
    final s = state;
    if (s == null) return;
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conversation_id'] as String?;
    if (convId == null) return;

    final idx = s.indexWhere((c) => c.id == convId);
    if (idx == -1) {
      final senderId = data['sender_id'] as String?;
      if (senderId == _agentId) load();
      return;
    }

    final senderId = data['sender_id'] as String?;
    final isOwn = senderId == _currentUserId;
    final isActive = convId == _activeConvId;
    final content = data['content'] as Map<String, dynamic>?;
    final createdAtStr = data['created_at'] as String?;
    final item = s[idx];

    // silent 消息不计未读（与 server IncrUnreadTx + bg-service + conversationProvider
    // 三路完全对齐）。silent=true 表示过程类消息,server 已跳过 IncrUnreadTx,
    // APP 端也必须跳过,否则徽章与 server unread_count 不一致。
    final isSilent = content?['silent'] == true;
    final newUnread = (!isOwn && !isActive && !isSilent)
        ? item.unreadCount + 1
        : item.unreadCount;
    final cardStatus =
        (content?['data'] as Map<String, dynamic>?)?['status'] as String?;
    final isPendingCard =
        (content?['msg_type'] == 'permission_card' ||
                content?['msg_type'] == 'question_card') &&
            cardStatus == 'pending';
    // 实时派生 lastUserMessageContent:仅 user 自己发的 text 消息更新
    // (与 server ListAgentSessionsForUser SQL 的 msg_type IN ('text','tui_user')
    // 规则对齐)。preview 函数对 tui_user 自带 [TUI] 前缀,与 server CASE 对齐。
    // tui_user 由 plugin 用 agent JWT 代发(sender_id=agent),isOwn 为 false,
    // 此处按 msg_type 归位为用户消息(与 chat page 的 effectiveIsMe = isMe || isTuiUser 同构)。
    final msgTypeStr = content?['msg_type'] as String?;
    final isUserTextMsg =
        (isOwn && msgTypeStr == 'text') || msgTypeStr == 'tui_user';
    final newLastUserMsg = isUserTextMsg
        ? (MsgTypeX.preview(
              MsgTypeX.fromString(msgTypeStr),
              content?['data'] as Map<String, dynamic>?,
            ) ?? item.lastUserMessageContent)
        : item.lastUserMessageContent;
    final newItem = item.copyWith(
      lastMessageContent: content,
      lastMessageAt: createdAtStr != null
          ? DateTime.parse(createdAtStr)
          : item.lastMessageAt,
      unreadCount: newUnread,
      pendingCount: isPendingCard ? item.pendingCount + 1 : item.pendingCount,
      lastUserMessageContent: newLastUserMsg,
    );
    final updated = List<Conversation>.from(s);
    updated[idx] = newItem;
    state = updated..sort(_compare);
  }

  void _onMessageUpdate(WSMessage m) {
    final s = state;
    if (s == null) return;
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conversation_id'] as String?;
    if (convId == null) return;

    final content = data['content'] as Map<String, dynamic>?;
    final msgType = content?['msg_type'] as String?;
    final status =
        (content?['data'] as Map<String, dynamic>?)?['status'] as String?;
    final isTerminalCard =
        (msgType == 'permission_card' || msgType == 'question_card') &&
            status != null &&
            status != 'pending';
    if (!isTerminalCard) return;

    final idx = s.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final item = s[idx];
    if (item.pendingCount <= 0) return;

    final updated = List<Conversation>.from(s);
    updated[idx] = item.copyWith(pendingCount: item.pendingCount - 1);
    state = updated;
  }

  void _onMessageRead(WSMessage m) {
    final s = state;
    if (s == null) return;
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conversation_id'] as String?;
    if (convId == null) return;
    final newUnread = (data['unread_count'] as num?)?.toInt() ?? 0;
    final idx = s.indexWhere((c) => c.id == convId);
    debugPrint(
      '[debug-agent-ws-read] MESSAGE_READ convId=$convId '
      'newUnread=$newUnread found in sessions? ${idx >= 0} '
      'sessions count=${s.length}',
    );
    if (idx == -1) return;
    final updated = List<Conversation>.from(s);
    updated[idx] = updated[idx].copyWith(unreadCount: newUnread);
    state = updated;
  }

  void markReadLocally(String convId) {
    final s = state;
    if (s == null) return;
    final idx = s.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    if (s[idx].unreadCount == 0) return;
    final updated = List<Conversation>.from(s);
    updated[idx] = updated[idx].copyWith(unreadCount: 0);
    state = updated;
  }

  void setUnreadCountLocally(String convId, int newUnread) {
    final s = state;
    if (s == null) return;
    final idx = s.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    if (s[idx].unreadCount == newUnread) return;
    final updated = List<Conversation>.from(s);
    updated[idx] = updated[idx].copyWith(unreadCount: newUnread);
    state = updated;
  }

  void incrementUnreadLocally(String convId) {
    final s = state;
    if (s == null) return;
    final idx = s.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final updated = List<Conversation>.from(s);
    updated[idx] = updated[idx].copyWith(
      unreadCount: updated[idx].unreadCount + 1,
    );
    state = updated;
  }

  Future<void> pin(String convId) async {
    await _api.pinConversation(convId);
    _updateItem(convId, (c) => c.copyWith(isPinned: true));
  }

  Future<void> unpin(String convId) async {
    await _api.unpinConversation(convId);
    _updateItem(convId, (c) => c.copyWith(isPinned: false));
  }

  Future<void> hide(String convId) async {
    await _api.hideConversation(convId);
    final s = state;
    if (s == null) return;
    state = s.where((c) => c.id != convId).toList();
  }

  void _updateItem(String convId, Conversation Function(Conversation) fn) {
    final s = state;
    if (s == null) return;
    final idx = s.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final updated = List<Conversation>.from(s);
    updated[idx] = fn(updated[idx]);
    state = updated..sort(_compare);
  }

  static int _compare(Conversation a, Conversation b) {
    if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
    return b.lastMessageAt.compareTo(a.lastMessageAt);
  }

  @override
  void dispose() {
    _msgSub?.cancel();
    _readSub?.cancel();
    _updateSub?.cancel();
    super.dispose();
  }
}

final agentSessionsProvider =
    StateNotifierProvider.family<
      AgentSessionsNotifier,
      List<Conversation>?,
      String
    >(
      (ref, agentId) => AgentSessionsNotifier(
        ref.watch(apiProvider),
        ref.watch(wsProvider),
        ref.watch(authProvider.select((s) => s.user?.id ?? '')),
        agentId,
      ),
    );
