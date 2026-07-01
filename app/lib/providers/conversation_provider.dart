import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

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

  ConversationListNotifier(this.api, this.ws, {bool autoload = true})
      : super([]) {
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
  }

  @override
  void dispose() {
    _subscription?.cancel();
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

  /// 拉取会话列表并替换当前 state。
  Future<void> load() async {
    final raw = await api.getConversations();
    // 切换账号时 apiProvider/wsProvider 重建会 dispose 本 notifier,
    // 但构造函数里 fire-and-forget 的 load() 可能仍在 await 中。
    // dispose 后再赋值 state 会抛 Bad state;在第一个 await 后守卫。
    if (!mounted) return;
    state = raw
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
    // 同步 agent avatar_url 到 bg-service isolate(供通知下载头像)
    syncAgentAvatarsToBgService(state);
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

    // agent → user 方向时本地 unreadCount++。
    // 但若用户当前正在该会话（_activeConvId），本地不计未读 —— 避免用户在看的
    // 会话还闪烁徽章。server 端已不再据此跳过 IncrUnread（一律计未读,client 端
    // _markRead 归零）,此处的本地判断纯属徽章 UX 优化。
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
  }

  void removeByAgentId(String agentId) {
    state = state.where((c) => c.agent!.id != agentId).toList();
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

/// 同步所有 agent 的 avatar_url 到 bg-service isolate(供通知下载头像)。
///
/// 在拉会话列表成功后调。原生平台未注册时 invoke 抛异常(测试环境),
/// 用 try-catch 兜底不阻塞 UI。
@visibleForTesting
void syncAgentAvatarsToBgService(List<Conversation> conversations) {
  try {
    final service = FlutterBackgroundService();
    for (final c in conversations) {
      final agentId = c.agent!.id;
      if (agentId.isEmpty) continue;
      service.invoke('syncAgentAvatar', {
        'agentId': agentId,
        'avatarUrl': c.agent!.avatarUrl,
      });
    }
  } catch (_) {
    // 原生平台未注册(测试环境)静默,不阻塞 UI
  }
}
