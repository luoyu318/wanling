import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import '../pages/wanling_page.dart' show WanlingAgentListPane;
import '../providers/no_conversation_hint_provider.dart';
import '../providers/selected_conv_provider.dart';
import '../widgets/agent_sessions_pane.dart';
import '../widgets/conversation_list.dart';
import 'app_canvas.dart';
import 'card_container.dart';

/// 浮动卡片壳:AppCanvas(画布 + 标题栏 + 工具条 + 双卡片)。
/// 左卡片由 [_ConversationCardHost] 按路由切换内容,右卡片 = 路由 child
/// (messages/wanling = 聊天卡片内容,settings = 设置页)。
class DesktopShell extends ConsumerWidget {
  final Widget child;

  const DesktopShell({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AppCanvas(
      conversationCard: _ConversationCardHost(),
      chatCard: child,
    );
  }
}

/// 会话卡片宿主:按当前路由选左卡片内容(路由 watch 与 NavRail 同款
/// GoRouterState.of),两级导航 state 自持(原消息/万灵页左栏迁入,
/// 全路由共享一份)。
/// - /messages:一级会话列表 / 二级该 agent 的 session 列表;
/// - /wanling:一级 agent 列表 / 二级该 agent 的 session 列表;
/// - /settings:无会话内容,空占位卡保持画布双卡结构。
class _ConversationCardHost extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ConversationCardHost> createState() =>
      _ConversationCardHostState();
}

class _ConversationCardHostState extends ConsumerState<_ConversationCardHost> {
  /// 二级模式:选中的 opencode agent id(null = 一级列表)。
  String? _sessionsAgentId;

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    if (location.startsWith('/settings')) {
      return const CardContainer(child: SizedBox.expand());
    }
    return CardContainer(
      child: location.startsWith('/wanling') ? _wanlingPane() : _messagesPane(),
    );
  }

  /// 消息路由:一级会话列表,二级该 agent 的 session 列表(带返回头)。
  Widget _messagesPane() {
    if (_sessionsAgentId != null) {
      return AgentSessionsPane(
        agentId: _sessionsAgentId!,
        onBack: () => setState(() => _sessionsAgentId = null),
        onOpenSession: (convId, agentId) {
          ref.read(selectedConvProvider.notifier).state = convId;
          ref.read(selectedAgentIdProvider.notifier).state = agentId;
        },
      );
    }
    return ConversationList(
      onOpenSessions: (agentId) => setState(() => _sessionsAgentId = agentId),
    );
  }

  /// 万灵路由:一级 agent 列表,二级该 agent 的 session 列表(带返回头)。
  Widget _wanlingPane() {
    if (_sessionsAgentId != null) {
      return AgentSessionsPane(
        agentId: _sessionsAgentId!,
        onBack: () => setState(() => _sessionsAgentId = null),
        onOpenSession: _openConversation,
      );
    }
    return WanlingAgentListPane(onAgentTap: _onAgentTap);
  }

  /// 一级 agent 点击(原万灵页逻辑迁入):opencode 进二级 session 列表;
  /// 其余直开该 agent 最新会话,无会话写提示并清选中。
  void _onAgentTap(Agent agent) {
    if (agent.type == AgentCategory.opencode) {
      // opencode:左卡片进入二级 session 列表。
      setState(() => _sessionsAgentId = agent.id);
      return;
    }
    final convs = ref
        .read(conversationProvider)
        .where((c) => c.agent?.id == agent.id)
        .toList()
      ..sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));

    if (convs.isEmpty) {
      ref.read(selectedConvProvider.notifier).state = null;
      ref.read(selectedAgentIdProvider.notifier).state = null;
      ref.read(noConversationHintProvider.notifier).state =
          '该 Agent 暂无会话，可从消息页发起';
      return;
    }
    _openConversation(convs.first.id, agent.id);
  }

  /// 选中会话 + agentId 兜底写入(agent_session 查不到 agent,靠
  /// selectedAgentIdProvider 兜底),聊天卡片打开。
  void _openConversation(String convId, String agentId) {
    ref.read(selectedConvProvider.notifier).state = convId;
    ref.read(selectedAgentIdProvider.notifier).state = agentId;
  }
}
