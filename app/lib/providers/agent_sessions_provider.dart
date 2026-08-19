import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_core/utils/diff_merge.dart';
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
    // 实时派生 lastAgentReplyContent:仅 agent 发的非 silent text/markdown 更新
    // (与 server ListAgentSessionsForUser SQL 的
    //  msg_type IN ('text','markdown') AND silent IS DISTINCT FROM 'true' 规则对齐)。
    // reasoning/step_finish/tool_card 等过程消息(silent=true)不覆盖简介。
    final msgTypeStr = content?['msg_type'] as String?;
    final isAgentReply = senderId == _agentId &&
        !isSilent &&
        (msgTypeStr == 'text' || msgTypeStr == 'markdown');
    final newLastAgentReply = isAgentReply
        ? (MsgTypeX.preview(
              MsgTypeX.fromString(msgTypeStr),
              content?['data'] as Map<String, dynamic>?,
            ) ?? item.lastAgentReplyContent)
        : item.lastAgentReplyContent;
    final newItem = item.copyWith(
      lastMessageContent: content,
      lastMessageAt: createdAtStr != null
          ? DateTime.parse(createdAtStr)
          : item.lastMessageAt,
      unreadCount: newUnread,
      pendingCount: isPendingCard ? item.pendingCount + 1 : item.pendingCount,
      lastAgentReplyContent: newLastAgentReply,
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
    if (isTerminalCard) {
      final idx = s.indexWhere((c) => c.id == convId);
      if (idx == -1) return;
      final item = s[idx];
      if (item.pendingCount <= 0) return;

      final updated = List<Conversation>.from(s);
      updated[idx] = item.copyWith(pendingCount: item.pendingCount - 1);
      state = updated;
      return;
    }

    // 聚合卡回合结束翻转:silent true→false → 徽章+1 + lastMessageContent 更新。
    // generating 阶段(silent 仍 true)只更新渲染(chatProvider),列表不动。
    // 增量 set_silent op 与全量替换统一走本地 _onAggregateCardFlip:
    // 广播 delta 带 data.preview(server 翻转时写入最后 markdown 正文),
    // 本地即可算摘要,无需 load() 拉 server 全量。
    // 不走 load() 的原因:load() 与 (2.7) markRead 竞态——load 拉到的 server
    // unread 可能是 markRead 生效前的旧值(1),diffMerge 用 fresh 覆盖本地
    // 已被 MESSAGE_READ 清零的 state,导致列表徽章残留(需手动刷新才消失)。
    if (msgType == 'aggregate_card' && content != null) {
      final data = content['data'];
      final isSetSilentDelta = data is Map && data['op'] == 'set_silent';
      final flipped = isSetSilentDelta
          ? data['silent'] == false
          : content['silent'] == false;
      if (flipped) {
        _onAggregateCardFlip(convId, content);
      }
    }
  }

  /// 聚合卡回合结束(silent true→false)翻转:徽章+1 + lastMessageContent 更新为
  /// 聚合卡 content(预览经 MsgTypeX.preview 取 preview 或最后 markdown 元素 text)
  /// + lastAgentReplyContent 同步更新(对齐 server SQL 新口径:
  /// aggregate_card 读 data.preview 也算「agent 回复摘要」)+ 排序。
  ///
  /// 全量替换与增量 set_silent 统一走本方法:set_silent 广播 delta 带
  /// data.preview(server 翻转时写入),本地即可算摘要;不走 load() 避免与
  /// MESSAGE_READ 竞态覆盖(见 _onMessageUpdate 注释)。delta 无 preview 时
  /// preview 为 null,lastAgentReplyContent 保留旧值(不退化覆盖)。
  void _onAggregateCardFlip(String convId, Map<String, dynamic> content) {
    final s = state;
    if (s == null) return;
    final idx = s.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final item = s[idx];
    // 与 _onMessageCreate 同口径:正在看该会话时不 +1(本地徽章 UX 优化)。
    final isActive = convId == _activeConvId;
    final preview = MsgTypeX.preview(
      MsgType.aggregateCard,
      content['data'] as Map<String, dynamic>?,
    );
    final updated = List<Conversation>.from(s);
    updated[idx] = item.copyWith(
      lastMessageContent: content,
      lastAgentReplyContent:
          (preview != null && preview.isNotEmpty)
              ? preview
              : item.lastAgentReplyContent,
      unreadCount: isActive ? item.unreadCount : item.unreadCount + 1,
    );
    state = updated..sort(_compare);
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
