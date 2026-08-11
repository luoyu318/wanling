import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/agent_sessions_provider.dart' show AgentSessionsNotifier;
import '../../providers/auth_provider.dart' show apiProvider;
import '../../providers/conversation_provider.dart' show conversationProvider;
import '../../utils/debug_log.dart';

/// [ConvSyncController] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次,把所有外部依赖打包传入,controller
/// 内部通过 `_ctx.xxx` 访问,实现解耦 + 可测试性。
@immutable
class ConvSyncContext {
  /// for conversationProvider / apiProvider.read。
  final WidgetRef ref;

  /// 当前会话 id(markRead / markReadLocally 目标)。
  final String convId;

  /// agent_id(null:user-user DM 会话无 agent,跳过 syncParentConvUnread)。
  final String? agentId;

  /// agent_session 的 sessions notifier(可 null:user-user DM 会话无 agent)。
  final AgentSessionsNotifier? Function() getSessionsNotifier;

  const ConvSyncContext({
    required this.ref,
    required this.convId,
    required this.agentId,
    required this.getSessionsNotifier,
  });
}

/// 会话已读同步控制器(方案 A:Controller class + 依赖注入)。
///
/// 封装 chat_page 原有的 2 个方法:
/// - [markRead](原 _markRead):本地立即清零 + API 同步 server。
/// - [syncParentConvUnread](原 _syncParentConvUnread):agent_session markRead
///   后同步父 dm_user_agent 会话未读数。
///
/// chat_page 在 initState 创建(在 _unreadTracker 之前,被后者依赖:
/// UnreadTrackerContext.onSyncParentConvUnread 指向本 controller)。
/// 无资源需手动 dispose。
class ConvSyncController {
  final ConvSyncContext _ctx;

  ConvSyncController(this._ctx);

  /// 标记会话已读:本地立即清零(conversationProvider + agent sessions)
  /// + API markConversationRead 同步 server,成功后刷新父会话未读数。
  Future<void> markRead() async {
    _ctx.ref.read(conversationProvider.notifier).markReadLocally(_ctx.convId);
    _ctx.getSessionsNotifier()?.markReadLocally(_ctx.convId);
    try {
      await _ctx.ref.read(apiProvider).markConversationRead(_ctx.convId);
      syncParentConvUnread();
    } catch (_) {
      // server 同步失败不影响本地已读清零,静默。
    }
  }

  /// agent_session markRead 后同步父 dm_user_agent 会话未读数。
  /// 一级列表持有 dm_user_agent 条目,未读针对父会话而非 agent_session,
  /// 所以 markRead agent_session 后必须刷新父会话的聚合未读。
  void syncParentConvUnread() {
    if (_ctx.agentId == null) return;
    final parentList = _ctx.ref.read(conversationProvider);
    final parent = parentList.where(
      (c) => c.isUserAgentDM && c.agent?.id == _ctx.agentId,
    ).firstOrNull;
    if (parent == null) {
      debugLog(
        '[syncParentConv] no dm_user_agent found for agentId=${_ctx.agentId} '
        'state has ${parentList.length} convs',
      );
      // 本地 state 可能不含 dm_user_agent 条目(例如列表未加载),
      // 调用 load 从 server 拉最新数据。
      _ctx.ref.read(conversationProvider.notifier).load();
      return;
    }
    debugLog(
      '[syncParentConv] parent convId=${parent.id} unread=${parent.unreadCount} '
      '→ refreshing from server',
    );
    _ctx.ref.read(conversationProvider.notifier).load();
  }
}
