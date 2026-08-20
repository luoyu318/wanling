import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/participant.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';

/// 详情侧栏「信息」tab:会话基础信息 + 环境(sessionMeta)+ 成员列表。
///
/// 数据源:conversationProvider 列表内会话(选中会话必在列表,含
/// participants/agent/sessionMeta 完整字段);列表查不到时标题/环境
/// 兜底读 chatProvider 已加载的 convTitle/sessionMeta(ChatView 打开
/// 会话时已初始化,无额外请求)。
class DetailInfoTab extends ConsumerWidget {
  final String convId;
  final String? agentId;

  const DetailInfoTab({super.key, required this.convId, this.agentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final conv = ref
        .watch(conversationProvider)
        .where((c) => c.id == convId)
        .firstOrNull;
    // 兜底:agent_session 等不在列表内的会话,读 chat 状态的标题/环境
    final chat =
        ref.watch(chatProvider((convId: convId, agentId: agentId)));
    final title = conv?.title?.isNotEmpty == true
        ? conv!.title!
        : (chat.convTitle ?? '会话');
    final meta = conv?.sessionMeta ?? chat.sessionMeta;
    final participants = conv?.participants ?? const <Participant>[];

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // 会话标题 + agent 名
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              if (conv?.agent != null) ...[
                const SizedBox(height: 4),
                Text(
                  conv!.agent!.name,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
              ],
            ],
          ),
        ),
        // 环境信息(仅展示非空字段)
        _Section(title: '环境', children: [
          if (conv?.directory?.isNotEmpty == true)
            _InfoRow(label: '工作目录', value: conv!.directory!),
          if (meta?.gitBranch?.isNotEmpty == true)
            _InfoRow(label: 'Git 分支', value: meta!.gitBranch!),
          if ((meta?.providerName ?? meta?.providerId)?.isNotEmpty == true)
            _InfoRow(
                label: 'Provider', value: meta!.providerName ?? meta.providerId),
          if ((meta?.modelName ?? meta?.modelId)?.isNotEmpty == true)
            _InfoRow(
                label: 'Model', value: meta!.modelName ?? meta.modelId),
          if (meta?.mode.isNotEmpty == true)
            _InfoRow(label: 'Mode', value: meta!.mode),
        ]),
        // 成员
        _Section(
          title: '成员 (${participants.length})',
          children: [
            for (final p in participants) _MemberTile(participant: p),
          ],
        ),
      ],
    );
  }
}

/// 分组区块:小节标题 + 子项列表(空 children 整组隐藏)。
class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

/// label-value 信息行。
class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 成员行:类型 icon + 显示名 + role 徽章(owner/admin)。
class _MemberTile extends StatelessWidget {
  final Participant participant;

  const _MemberTile({required this.participant});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = participant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Row(
        children: [
          Icon(
            p.isAgent ? Icons.smart_toy_outlined : Icons.person_outline,
            size: 16,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              p.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
          if (p.isOwner || p.isAdmin)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: (p.isOwner ? const Color(0xFFE6A23C) : scheme.primary)
                    .withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                p.isOwner ? '群主' : '管理员',
                style: TextStyle(
                  fontSize: 10,
                  color:
                      p.isOwner ? const Color(0xFFE6A23C) : scheme.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
