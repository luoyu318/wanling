import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/conversation.dart';
import '../models/ws_message.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
// 复用现有 provider，避免重复定义导致状态分裂。
import 'auth_provider.dart' show apiProvider;
import 'chat_provider.dart' show wsProvider;

/// 会话列表状态管理：负责拉取会话列表，并订阅 WebSocket MESSAGE_CREATE 事件，
/// 在本地更新最近一条消息预览并把对应会话置顶。
class ConversationListNotifier extends StateNotifier<List<Conversation>> {
  final ApiService api;
  final WebSocketService ws;
  StreamSubscription<WSMessage>? _subscription;
  // 当前打开的 ChatPage convId。该会话收到的 agent 消息不计未读（用户正在看）。
  String? _activeConvId;

  ConversationListNotifier(this.api, this.ws) : super([]) {
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
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  /// ChatPage 进入/离开时切换激活会话。激活期间 incoming 消息不计未读。
  void setActiveConv(String? convId) {
    _activeConvId = convId;
  }

  /// 拉取会话列表并替换当前 state。
  Future<void> load() async {
    final raw = await api.getConversations();
    state = raw
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  void _onMessageCreate(WSMessage m) {
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conversation_id'] as String?;
    if (convId == null) return;

    final senderType = data['sender_type'] as String?;
    final isAgent = senderType == 'agent';

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

    // agent → user 方向时本地 unreadCount++（与服务端逻辑对齐）。
    // 但若用户当前正在该会话（_activeConvId），不计未读 —— 用户已经在看了。
    final isActive = convId == _activeConvId;
    final newUnread =
        (isAgent && !isActive) ? item.unreadCount + 1 : item.unreadCount;

    // copyWith 保留 isPinned 等其它字段；直接 Conversation(...) 会丢 isPinned
    // 导致置顶背景色被刷掉。
    final newItem = item.copyWith(
      lastMessageContent: content,
      lastMessageAt: lastMessageAt,
      unreadCount: newUnread,
    );
    // 用 _resort 重排：置顶组在前，组内按 lastMessageAt 倒序。
    // 直接 prepend 会破坏置顶/非置顶分组。
    state = [...state.where((c) => c.id != convId), newItem];
    _resort();
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
  }

  void removeByAgentId(String agentId) {
    state = state.where((c) => c.agent.id != agentId).toList();
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
  }

  /// 置顶会话。调 API + 本地乐观更新 + resort。
  Future<void> pin(String convId) async {
    await api.pinConversation(convId);
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    state = List<Conversation>.from(state)
      ..[idx] = state[idx].copyWith(isPinned: true);
    _resort();
  }

  /// 取消置顶。
  Future<void> unpin(String convId) async {
    await api.unpinConversation(convId);
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    state = List<Conversation>.from(state)
      ..[idx] = state[idx].copyWith(isPinned: false);
    _resort();
  }

  /// 软删除会话。调 API + 本地移除。
  Future<void> hide(String convId) async {
    await api.hideConversation(convId);
    state = state.where((c) => c.id != convId).toList();
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
  return ConversationListNotifier(
    ref.watch(apiProvider),
    ref.watch(wsProvider),
  );
});

/// 总未读数。HomePage 消息 tab badge 用。
/// 单独 provider 避免每次 list 变化都重建 HomePage 全部子树。
final totalUnreadProvider = Provider<int>((ref) {
  final list = ref.watch(conversationProvider);
  return list.fold(0, (sum, c) => sum + c.unreadCount);
});
