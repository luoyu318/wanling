import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../models/conversation.dart';
import '../models/participant.dart';
import '../models/ws_message.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
// 复用现有 provider，避免重复定义导致状态分裂。
import 'auth_provider.dart' show apiProvider, authProvider;
import 'chat_provider.dart' show wsProvider;

/// 会话列表状态管理：负责拉取会话列表，并订阅 WebSocket MESSAGE_CREATE 事件，
/// 在本地更新最近一条消息预览并把对应会话置顶。
class ConversationListNotifier extends StateNotifier<List<Conversation>> {
  final ApiService api;
  final WebSocketService ws;
  /// 当前 user.id。用于 _onMessageCreate 判断「自己发的消息不计未读」。
  /// participants 模型下 sender 可能是 user 也可能是 agent,只要不是自己发的就算未读。
  final String currentUserId;
  StreamSubscription<WSMessage>? _subscription;
  StreamSubscription<WSMessage>? _conversationEventsSub;
  // 当前打开的 ChatPage convId。该会话收到的 agent 消息不计未读（用户正在看）。
  String? _activeConvId;

  ConversationListNotifier(
    this.api,
    this.ws,
    this.currentUserId, {
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
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _conversationEventsSub?.cancel();
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

    // 非自己发的消息且不在该会话页时本地 unreadCount++。
    // 但若用户当前正在该会话（_activeConvId），本地不计未读 —— 避免用户在看的
    // 会话还闪烁徽章。server 端已不再据此跳过 IncrUnread（一律计未读,client 端
    // _markRead 归零）,此处的本地判断纯属徽章 UX 优化。
    final isActive = convId == _activeConvId;
    final newUnread =
        (!isOwn && !isActive) ? item.unreadCount + 1 : item.unreadCount;

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
    // dm_user_user / 群聊的 agent=null（agentId != null 必然 != null → true，保留）。
    state = state.where((c) => c.agent?.id != agentId).toList();
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

  // === N 方 participants 模型:群管理方法 ===

  /// 创建群聊(type=group_user 默认;群成员从好友列表选)。
  /// 成功后返回新会话 ID(供调用方 push 到 ChatPage)。
  Future<String> createGroup({
    required List<String> memberIds,
    String? title,
    String? avatarUrl,
  }) async {
    final raw = await api.createConversation(
      type: 'group_user',
      memberIds: memberIds,
      memberTypes: memberIds.map((_) => 'user').toList(),
      title: title,
      avatarUrl: avatarUrl,
    );
    final conv = Conversation.fromJson(raw as Map<String, dynamic>);
    // 乐观本地插入(创建者是 owner,自动加为 participant 由 server 处理)
    state = [conv, ...state];
    _resort();
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
  }

  /// 处理 CONVERSATION_UPDATE 事件(群名 / 群头像变更)。
  void _onConversationUpdate(WSMessage m) {
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conv_id'] as String?;
    if (convId == null) return;
    final idx = state.indexWhere((c) => c.id == convId);
    if (idx == -1) return;
    final item = state[idx];
    final updated = List<Conversation>.from(state);
    updated[idx] = item.copyWith(
      title: (data['title'] as String?) ?? item.title,
      avatarUrl: (data['avatar_url'] as String?) ?? item.avatarUrl,
    );
    state = updated;
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
    ref.watch(authProvider.select((s) => s.user?.id ?? '')),
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
