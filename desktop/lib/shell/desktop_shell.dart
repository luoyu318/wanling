// desktop/lib/shell/desktop_shell.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../pages/wanling_page.dart' show WanlingAgentListPane;
import '../providers/open_agent_sessions_provider.dart';
import '../providers/selected_conv_provider.dart';
import '../providers/tab_reselect_provider.dart';
import '../widgets/agent_sessions_pane.dart';
import '../widgets/conversation_list.dart';
import '../widgets/settings_nav_pane.dart';
import 'app_canvas.dart';
import 'card_container.dart';

/// 浮动卡片壳:AppCanvas(画布 + 标题栏 + 工具条 + 双卡片)。
/// 左卡片由 [_ConversationCardHost] 按路由切换内容,右卡片 = 路由 child
/// (messages/wanling = 聊天卡片内容,agent/:id = 详情页,settings = 设置页)。
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
/// - /wanling(含 /agent/:id 详情页期间):一级 agent 列表 / 二级该
///   agent 的 session 列表;
/// - /settings:无会话内容,空占位卡保持画布双卡结构。
/// 二级切换入口:一级列表 onOpenSessions(消息页)+ 详情页 CTA
/// 「进入会话」经 openAgentSessionsProvider 脉冲触发(消费后清零)。
class _ConversationCardHost extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ConversationCardHost> createState() =>
      _ConversationCardHostState();
}

class _ConversationCardHostState extends ConsumerState<_ConversationCardHost> {
  /// 二级模式:选中的 opencode agent id(null = 一级列表)。
  String? _sessionsAgentId;

  /// 上次路由分支(messages/wanling/settings),用于检测 tab 切换。
  String _lastBranch = '';

  /// 路由分支:二级状态按分支隔离——切 tab(消息↔万灵↔设置)时
  /// 重置 _sessionsAgentId 回一级,防二级列表跨 tab 残留。
  String _branchOf(String location) {
    if (location.startsWith('/settings')) return 'settings';
    if (location.startsWith('/wanling') || location.startsWith('/agent')) {
      return 'wanling';
    }
    return 'messages';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final branch = _branchOf(GoRouterState.of(context).uri.path);
    if (_lastBranch.isNotEmpty &&
        branch != _lastBranch &&
        _sessionsAgentId != null) {
      setState(() => _sessionsAgentId = null);
    }
    _lastBranch = branch;
  }

  @override
  Widget build(BuildContext context) {
    // 详情页「进入会话」脉冲:消费后立即清零,防残留误触发。
    ref.listen(openAgentSessionsProvider, (prev, next) {
      if (next != null) {
        setState(() => _sessionsAgentId = next);
        ref.read(openAgentSessionsProvider.notifier).state = null;
      }
    });
    // 重复点击当前 tab 脉冲:清二级 session 列表回一级(消费后清零)。
    ref.listen(tabReselectProvider, (prev, next) {
      if (next != null) {
        if (_sessionsAgentId != null) {
          setState(() => _sessionsAgentId = null);
        }
        ref.read(tabReselectProvider.notifier).state = null;
      }
    });
    final location = GoRouterState.of(context).uri.path;
    if (_branchOf(location) == 'settings') {
      // 设置分支:左卡片放分区导航(与右卡片 SettingsPage 经 provider 联动)。
      return const CardContainer(child: SettingsNavPane());
    }
    return CardContainer(
      child: _branchOf(location) == 'wanling'
          ? _wanlingPane()
          : _messagesPane(),
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

  /// 万灵路由:一级 agent 列表(点击推入详情页),二级该 agent 的
  /// session 列表(带返回头)。选中写万灵 tab 独立 provider(与消息
  /// tab 隔离,见 selectedWanlingConvProvider 注释)。
  Widget _wanlingPane() {
    if (_sessionsAgentId != null) {
      return AgentSessionsPane(
        agentId: _sessionsAgentId!,
        onBack: () => setState(() => _sessionsAgentId = null),
        onOpenSession: _openConversation,
        // 选中高亮读万灵 tab 独立选中态。
        selectedConvId: ref.watch(selectedWanlingConvProvider),
      );
    }
    return WanlingAgentListPane(
      onAgentTap: (agent) => context.push('/agent/${agent.id}'),
    );
  }

  /// 万灵 tab 选中会话 + agentId 兜底写入(独立 provider,不污染消息
  /// tab 的选中态;agent_session 查不到 agent,靠
  /// selectedWanlingAgentIdProvider 兜底),聊天卡片打开。
  void _openConversation(String convId, String agentId) {
    ref.read(selectedWanlingConvProvider.notifier).state = convId;
    ref.read(selectedWanlingAgentIdProvider.notifier).state = agentId;
  }
}
