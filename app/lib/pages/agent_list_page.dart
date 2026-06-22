import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/agent.dart';
import '../providers/agent_provider.dart';
import '../providers/conversation_provider.dart';
import '../widgets/avatar.dart';

class AgentListPage extends ConsumerStatefulWidget {
  const AgentListPage({super.key});

  @override
  ConsumerState<AgentListPage> createState() => _AgentListPageState();
}

class _AgentListPageState extends ConsumerState<AgentListPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 必须调
    final agents = ref.watch(agentListProvider);

    // AppBar 移到 HomePage 共享管理。整页白底。
    // RefreshIndicator 始终包裹（含空状态）：空状态用 ListView 包裹，
    // 配合 AlwaysScrollableScrollPhysics 让空列表也能下拉。
    return ColoredBox(
      color: Colors.white,
      child: RefreshIndicator(
        onRefresh: () => ref.read(agentListProvider.notifier).load(),
        child: agents.isEmpty
            ? ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 200),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('暂无 Agent',
                            style: TextStyle(color: Color(0xFF999999))),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: () => _showCreateDialog(context, ref),
                          child: const Text('新建 Agent'),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : _AgentListView(agents: agents),
      ),
    );
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建 Agent'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Agent 名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = ctrl.text.trim();
              if (name.isEmpty) return;
              ref.read(agentListProvider.notifier).create(name);
              Navigator.pop(ctx);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }
}

/// AgentListPage 的列表部分。单独抽出来是为了把 conversationProvider 的
/// watch 放在 build() 一次性算出 agentId→unread map，避免在 itemBuilder 里
/// 每 item 一次 watch（N 次 subscription + 每 WS event O(N²) 重建）。
class _AgentListView extends ConsumerWidget {
  final List<Agent> agents;
  const _AgentListView({required this.agents});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final convs = ref.watch(conversationProvider);
    // 一次性算出 agentId → 未读累加 map（O(convs)）
    final unreadByAgent = <String, int>{};
    for (final c in convs) {
      final aid = c.agent.id;
      unreadByAgent[aid] = (unreadByAgent[aid] ?? 0) + c.unreadCount;
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: agents.length,
      itemBuilder: (_, i) {
        final a = agents[i];
        return _AgentTile(
          agent: a,
          unreadCount: unreadByAgent[a.id] ?? 0,
          // 整行点击进详情页（详情页里有「发消息」CTA 入会话）
          onTap: () => context.push('/agent/${a.id}'),
        );
      },
    );
  }
}

/// 紧凑列表行：整行点击进详情页
class _AgentTile extends StatefulWidget {
  final Agent agent;
  final int unreadCount;
  final VoidCallback onTap;

  const _AgentTile({
    required this.agent,
    required this.unreadCount,
    required this.onTap,
  });

  @override
  State<_AgentTile> createState() => _AgentTileState();
}

class _AgentTileState extends State<_AgentTile> {
  bool _isPressed = false;
  Offset? _downPos; // 记录按下位置，检测滑动距离

  void _setPressed(bool v) {
    if (_isPressed == v) return;
    setState(() => _isPressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    // tile 背景：按下时变更反馈色（白 → #EDEDED），松开恢复
    final tileBg =
        _isPressed ? const Color(0xFFEDEDED) : Colors.white;

    // Listener 包最外层：onPointerDown 绕过 gesture arena，按下立即变色
    // （InkWell.onTapDown 要等 arena 解决，快速点击看不到反馈）。
    return Listener(
      onPointerDown: (e) {
        _downPos = e.position;
        _setPressed(true);
      },
      // 滑动超过 8px 视为滚动，立即归位避免背景色卡住
      onPointerMove: (e) {
        if (_downPos != null &&
            (e.position - _downPos!).distance > 8) {
          _setPressed(false);
        }
      },
      onPointerUp: (_) {
        _downPos = null;
        _setPressed(false);
      },
      onPointerCancel: (_) {
        _downPos = null;
        _setPressed(false);
      },
      child: InkWell(
        onTap: widget.onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Column(
          children: [
            Container(
              color: tileBg,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              child: Row(
                children: [
                  Avatar(
                    name: agent.name,
                    url: agent.avatarUrl,
                    unreadCount: widget.unreadCount,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          agent.name,
                          style: const TextStyle(
                              fontSize: 15,
                              color: Color(0xFF111111),
                              fontWeight: FontWeight.w300),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: agent.status == AgentStatus.online
                                    ? const Color(0xFF07C160)
                                    : const Color(0xFFCCCCCC),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              agent.status == AgentStatus.online
                                  ? '在线'
                                  : '离线',
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF999999),
                                  fontWeight: FontWeight.w300),
                            ),
                            // 简介非空：状态右侧竖线 + bio（单行省略）
                            if (agent.bio != null && agent.bio!.isNotEmpty) ...[
                              Text(
                                '  |  ',
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFFCCCCCC),
                                    fontWeight: FontWeight.w300),
                              ),
                              Expanded(
                                child: Text(
                                  agent.bio!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF999999),
                                      fontWeight: FontWeight.w300),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // 分割线区域：外层填白与 tile 同色无缝；内层从 left=62 开始画线段
            // 62 = 12 padding + 40 avatar + 10 spacing
            Container(
              height: 0.5,
              color: Colors.white,
              child: Container(
                margin: const EdgeInsets.only(left: 62),
                color: const Color(0xFFE4E4E4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
