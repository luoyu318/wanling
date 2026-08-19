import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/agent_sessions_provider.dart' show AgentSessionsNotifier;
import '../../providers/auth_provider.dart' show apiProvider;
import '../../providers/chat_provider.dart' show chatProvider;
import '../../providers/conversation_provider.dart' show conversationProvider;
import 'package:wanling_core/utils/debug_log.dart';
import 'package:wanling_core/utils/chat/unread_tracker.dart' show computeNewlySeenUnread;

/// [UnreadTrackerController] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次,把所有外部依赖打包传入,controller
/// 内部通过 `_ctx.xxx` 访问,实现解耦 + 可测试性。
@immutable
class UnreadTrackerContext {
  /// for chatProvider / apiProvider / conversationProvider.read。
  final WidgetRef ref;

  /// chatProvider family key。
  final ({String convId, String? agentId}) chatKey;

  /// 替代 widget.mounted(dispose 后不再读 ref / 调度 timer 回调)。
  final bool Function() isMounted;

  /// 定位中不检查未读(从 UnreadLocatorController 读)。
  final bool Function() isLocating;

  /// 视口判断(从 UnreadLocatorController 调)。
  final bool Function(String msgId) isMessageInViewport;

  /// flush 后同步父会话未读(回调 chat_page._syncParentConvUnread)。
  final VoidCallback onSyncParentConvUnread;

  /// agent_session 的 sessions notifier(可 null:user-user DM 会话无 agent)。
  final AgentSessionsNotifier? Function() getSessionsNotifier;

  const UnreadTrackerContext({
    required this.ref,
    required this.chatKey,
    required this.isMounted,
    required this.isLocating,
    required this.isMessageInViewport,
    required this.onSyncParentConvUnread,
    required this.getSessionsNotifier,
  });
}

/// 已读上报相关逻辑的状态/行为控制器(方案 A:Controller class + 依赖注入)。
///
/// 封装 chat_page 原有的 3 个方法 + 3 个状态字段:
/// - [_seenUnreadMsgIds] 状态(原 chat_page 字段)
/// - [_pendingReadMsgIds] 状态(原 chat_page 字段)
/// - [_markReadDebounce] 状态(原 chat_page 字段)
/// - [checkUnreadSeen](原 _checkUnreadSeen)
/// - [scheduleMarkReadSync](原 _scheduleMarkReadSync)
/// - [flushPendingReadMsgIds](原 _flushPendingReadMsgIds)
///
/// chat_page 在 initState 创建(_unreadLocator 之后,依赖其 isLocating /
/// isMessageInViewport)。dispose 在 _unreadLocator 之前(被依赖者先释放)。
/// _onScroll 的 PostFrameCallback 与 _unreadLocator.onLocateComplete 调
/// [checkUnreadSeen];dispose 时 pending timer 立即 flush 兜底。
class UnreadTrackerController {
  final UnreadTrackerContext _ctx;

  UnreadTrackerController(this._ctx);

  /// 已视口见过的未读 msg id(防重复 decrement)。
  final Set<String> _seenUnreadMsgIds = {};

  /// 待同步给 server 的已读 msg id(debounce 期间累积)。
  final Set<String> _pendingReadMsgIds = {};

  /// markRead debounce timer。
  Timer? _markReadDebounce;

  /// 检测视口内的未读消息，把新进入视口的未读批量加入 _seenUnreadMsgIds
  /// 并调 decrementUnread(N)。
  ///
  /// 触发点：
  /// - _onScroll 每次滚动的 PostFrameCallback
  /// - _unreadLocator 定位完成的 PostFrameCallback（onLocateComplete 回调）
  ///
  /// 算法：messages 是 newest first，messages[0] = 最新未读，
  /// messages[firstUnreadIdx] = 第一条未读（最老）。
  /// 未读段 = messages[0..firstUnreadIdx]，遍历找「在视口内 + 未在 seen 集合」的。
  void checkUnreadSeen() {
    if (!_ctx.isMounted() || _ctx.isLocating()) return;
    final chatState = _ctx.ref.read(chatProvider(_ctx.chatKey));
    if (chatState.unreadCount == 0 || chatState.firstUnreadMessageId == null) {
      return;
    }

    // 不缓存 idx：messages 长度可能因新消息 prepend / 删除变化，缓存会偏移导致误算。
    final firstUnreadIdx = chatState.displayMessages.indexWhere(
      (m) => m.id == chatState.firstUnreadMessageId,
    );
    if (firstUnreadIdx < 0) return;

    final newlySeen = computeNewlySeenUnread(
      messages: chatState.displayMessages,
      firstUnreadIdx: firstUnreadIdx,
      seenUnreadMsgIds: _seenUnreadMsgIds,
      isInViewport: _ctx.isMessageInViewport,
    );
    if (newlySeen.isEmpty) return;

    debugLog(
      '[unreadCheck] idx=$firstUnreadIdx, unread=${chatState.unreadCount}, '
      'seen=${_seenUnreadMsgIds.length}, newlySeen=${newlySeen.length}',
    );
    _seenUnreadMsgIds.addAll(newlySeen);
    _ctx.ref.read(chatProvider(_ctx.chatKey).notifier).decrementUnread(newlySeen.length);
    scheduleMarkReadSync(newlySeen);
  }

  /// 启动 markMessagesRead 同步 debounce：累积 msgIds 到 _pendingReadMsgIds,
  /// 500ms 内若再次调用则重置 timer（取最后一次），fling 期间不打 server。
  void scheduleMarkReadSync(List<String> msgIds) {
    if (msgIds.isEmpty) return;
    _pendingReadMsgIds.addAll(msgIds);
    _markReadDebounce?.cancel();
    _markReadDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!_ctx.isMounted()) return;
      flushPendingReadMsgIds();
    });
  }

  /// 把 _pendingReadMsgIds 一次性同步给 server，清空集合。
  /// 调 markMessagesRead API，server 返回新 unread_count 后同步到 conversationProvider
  /// 让会话列表徽章立即对齐。
  Future<void> flushPendingReadMsgIds() async {
    if (_pendingReadMsgIds.isEmpty) return;
    final ids = _pendingReadMsgIds.toList();
    _pendingReadMsgIds.clear();
    debugLog('[markSync] FLUSH: syncing ${ids.length} ids to server');
    try {
      // API 已返 record ({int unreadCount})(Task 16),无需 Map 访问。
      final res = await _ctx.ref
          .read(apiProvider)
          .markMessagesRead(_ctx.chatKey.convId, ids);
      final newUnread = res.unreadCount;
      // 同步 conversationProvider 的本地未读数（让会话列表徽章立即更新）
      _ctx.ref
          .read(conversationProvider.notifier)
          .setUnreadCountLocally(_ctx.chatKey.convId, newUnread);
      _ctx.getSessionsNotifier()
          ?.setUnreadCountLocally(_ctx.chatKey.convId, newUnread);
      _ctx.onSyncParentConvUnread();
      debugLog('[markSync] flushed, server unread_count=$newUnread');
    } catch (e) {
      debugLog('[markSync] flush failed: $e');
      // 失败不重试，下次进入会话 server 仍是旧值，可接受（用户重进会重新触发同步）
    }
  }

  /// 释放 debounce timer。
  /// 注:chat_page dispose 在 pending 时主动调 [flushPendingReadMsgIds]
  /// 兜底,本方法只负责 cancel timer(避免 timer fire 后 setState-after-dispose)。
  void dispose() {
    _markReadDebounce?.cancel();
  }
}
