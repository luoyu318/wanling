import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/message.dart';
import '../models/msg_type.dart';
import '../models/ws_message.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import 'auth_provider.dart';
import 'settings_provider.dart';

class ChatNotifier extends StateNotifier<List<ChatMessage>> {
  final ApiService api;
  final WebSocketService ws;
  final String conversationId;
  final String agentId;
  StreamSubscription<WSMessage>? _subscription;

  int _page = 0;
  final int _pageSize = 20;
  bool _hasMore = true;
  bool _loadingMore = false;

  bool get hasMore => _hasMore;
  bool get loadingMore => _loadingMore;

  ChatNotifier(this.api, this.ws, this.conversationId, this.agentId) : super([]) {
    _loadHistory();
    _listenWS();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  // API 返回 newest first，保持此顺序配合 ListView(reverse: true)
  List<ChatMessage> _parseMessages(List msgs) {
    return msgs.map((e) => ChatMessage.fromJson(e)).toList();
  }

  Future<void> _loadHistory() async {
    final msgs = await api.getMessages(conversationId, limit: _pageSize, offset: 0);
    final parsed = _parseMessages(msgs);
    _page = 1;
    _hasMore = parsed.length == _pageSize;
    _mergeHistory(parsed);
  }

  Future<void> loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;

    final msgs = await api.getMessages(conversationId, limit: _pageSize, offset: _page * _pageSize);
    final parsed = _parseMessages(msgs);
    _hasMore = parsed.length == _pageSize;
    _page++;
    _mergeHistory(parsed);
    _loadingMore = false;
  }

  /// 把网络加载的消息合并进 state。保留 state 中并发 WS 到达、但网络结果
  /// 中未包含的新消息（如 _loadHistory 的 API 调用期间 WS 新增的消息），
  /// 避免直接覆盖丢失数据。
  void _mergeHistory(List<ChatMessage> loaded) {
    final loadedIds = loaded.map((m) => m.id).toSet();
    final extra = state.where((m) => !loadedIds.contains(m.id)).toList();
    state = [...extra, ...loaded]; // newest first 顺序
  }

  void _listenWS() {
    _subscription = ws.messages
      .where((m) => m.t == 'MESSAGE_CREATE' || m.t == 'MESSAGE_DELETE')
      .listen((m) {
        if (m.t == 'MESSAGE_DELETE') {
          // 另一端(或本端删除)广播的删除事件:从 state 移除对应 ids。
          final msgData = m.d as Map<String, dynamic>;
          if (msgData['conversation_id'] == conversationId) {
            final ids = (msgData['ids'] as List).cast<String>().toSet();
            state = state.where((msg) => !ids.contains(msg.id)).toList();
          }
          return;
        }
        final msgData = m.d as Map<String, dynamic>;
        if (msgData['conversation_id'] == conversationId) {
          final msg = ChatMessage.fromJson(msgData);
          // 去重：WS Resume 重连会重播 buffer 内的消息，按 id 跳过已存在的。
          // history 加载也会把消息拉进 state，echo 回来时如果 id 已存在则跳过。
          if (state.any((c) => c.id == msg.id)) return;
          state = [msg, ...state];
        }
      });
  }

  void sendText(String text) {
    ws.sendMessage(agentId, {
      'msg_type': MsgType.text.value,
      'data': {'text': text},
    });
  }

  void sendFile(String fileId, MsgType msgType) {
    ws.sendMessage(agentId, {
      'msg_type': msgType.value,
      'data': {'file_id': fileId},
    });
  }

  /// 删除消息。乐观更新(先移 UI)+ 调 API,失败回滚(重拉历史)。
  /// 单条走 deleteMessage,多条走 batchDeleteMessages。
  Future<void> deleteMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    final idSet = ids.toSet();
    // 乐观更新:先从 state 移除
    state = state.where((m) => !idSet.contains(m.id)).toList();
    try {
      if (ids.length == 1) {
        await api.deleteMessage(ids.first);
      } else {
        await api.batchDeleteMessages(ids);
      }
    } catch (e) {
      // 失败回滚:重拉历史(简单可靠,不用维护 undo 快照)
      await _loadHistory();
      rethrow; // 让 UI 层弹 Snackbar
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

/// family key 用 record：convId 决定历史拉取与 WS 过滤，
/// agentId 决定发送目标。两者共同唯一确定一个聊天上下文。
final chatProvider = StateNotifierProvider.family<ChatNotifier, List<ChatMessage>, ({String convId, String agentId})>((ref, key) {
  return ChatNotifier(
    ref.watch(apiProvider),
    ref.watch(wsProvider),
    key.convId,
    key.agentId,
  );
});
