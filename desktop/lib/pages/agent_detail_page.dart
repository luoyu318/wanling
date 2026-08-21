// desktop/lib/pages/agent_detail_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/utils/snackbar.dart';

import '../providers/no_conversation_hint_provider.dart';
import '../providers/open_agent_sessions_provider.dart';
import '../providers/selected_conv_provider.dart';
import '../shell/card_container.dart';
import '../theme/desktop_theme.dart';
import '../widgets/avatar.dart';

/// Agent 详情页(桌面卡片版,参考 app 端 IM 个人资料风格):
/// - 顶部横幅:大头像 + 名称/类型徽标/在线状态 + bio
/// - AppID 行:SelectableText + 复制
/// - 操作组:编辑资料 / 重置密钥 / 删除
/// - 底部 CTA:多 session 型(opencode)「进入会话」进二级列表,其余
///   「发消息」直开该 agent 最新会话
///
/// 无 Scaffold(由 DesktopShell 装进聊天卡槽);不做换头像(桌面无
/// 裁剪页基建,YAGNI)。
class AgentDetailPage extends ConsumerWidget {
  final String agentId;

  const AgentDetailPage({super.key, required this.agentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref
        .watch(agentListProvider)
        .where((a) => a.id == agentId)
        .firstOrNull;
    final scheme = Theme.of(context).colorScheme;

    if (agent == null) {
      return CardContainer(
        child: Center(
          child: Text(
            'Agent 不存在',
            style: TextStyle(
              fontSize: 14,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
        ),
      );
    }

    final online = agent.status == AgentStatus.online;
    final multi = AgentCategory.supportsMultiSession(agent.type);

    return CardContainer(
      color: DesktopTheme.chatCardColor(Theme.of(context).brightness),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶部横幅:头像 + 名称/徽标/状态/bio。
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Avatar(
                  name: agent.name,
                  url: agent.avatarUrl,
                  size: 60,
                  radius: 8,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              agent.name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          _TypeBadge(type: agent.type),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: online
                                  ? const Color(0xFF07C160)
                                  : const Color(0xFF999999),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            online ? '在线' : '离线',
                            style: TextStyle(
                              fontSize: 12,
                              color: online
                                  ? const Color(0xFF07C160)
                                  : const Color(0xFF999999),
                            ),
                          ),
                        ],
                      ),
                      if (agent.bio != null && agent.bio!.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          agent.bio!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurface.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _AppIdRow(value: agent.id),
            const SizedBox(height: 8),
            // 操作组:ListTile 风格行,删除红。
            _ActionRow(
              icon: Icons.edit_outlined,
              label: '编辑资料',
              onTap: () => _editProfile(context, ref, agent),
            ),
            const Divider(height: 1),
            _ActionRow(
              icon: Icons.vpn_key_outlined,
              label: '重置密钥',
              onTap: () => _rotateSecret(context, ref, agent),
            ),
            const Divider(height: 1),
            _ActionRow(
              icon: Icons.delete_outline,
              label: '删除 Agent',
              color: const Color(0xFFFA5151),
              onTap: () => _delete(context, ref, agent),
            ),
            const Spacer(),
            // 底部 CTA:全宽 primary 按钮。
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: () {
                  if (multi) {
                    // 脉冲通知壳层切二级列表后回万灵页。
                    ref.read(openAgentSessionsProvider.notifier).state =
                        agent.id;
                    context.go('/wanling');
                  } else {
                    _startChat(context, ref, agent);
                  }
                },
                child: Text(multi ? '进入会话' : '发消息'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 「发消息」(原万灵页一级点击逻辑迁入):取该 agent 最新会话直开;
  /// 无会话清选中并写提示,均回万灵页展示。
  void _startChat(BuildContext context, WidgetRef ref, Agent agent) {
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
    } else {
      ref.read(selectedConvProvider.notifier).state = convs.first.id;
      ref.read(selectedAgentIdProvider.notifier).state = agent.id;
    }
    context.go('/wanling');
  }

  /// 编辑资料:昵称/简介/类型弹窗统一保存。
  void _editProfile(BuildContext context, WidgetRef ref, Agent agent) {
    final nameCtrl = TextEditingController(text: agent.name);
    final bioCtrl = TextEditingController(text: agent.bio ?? '');
    String agentType = agent.type;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑资料'),
        content: StatefulBuilder(
          builder: (_, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '昵称'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: bioCtrl,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(labelText: '简介'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: agentType,
                decoration: const InputDecoration(labelText: '类型'),
                items: const [
                  DropdownMenuItem(value: '', child: Text('普通')),
                  DropdownMenuItem(
                    value: AgentCategory.hermes,
                    child: Text('Hermes'),
                  ),
                  DropdownMenuItem(
                    value: AgentCategory.opencode,
                    child: Text('OpenCode'),
                  ),
                ],
                onChanged: (v) => setDialogState(() => agentType = v ?? ''),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              try {
                await ref.read(agentListProvider.notifier).update(
                      agent.id,
                      name: nameCtrl.text.trim(),
                      bio: bioCtrl.text.trim(),
                      type: agentType,
                    );
              } catch (e) {
                if (context.mounted) {
                  showAppSnackBar(
                    context,
                    '修改失败: $e',
                    type: SnackBarType.error,
                  );
                }
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 重置密钥:确认 → 调 API → 新密钥一次性弹窗(带复制)。
  void _rotateSecret(BuildContext context, WidgetRef ref, Agent agent) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置密钥'),
        content: const Text(
          '重置密钥后旧连接立即失效，需用新密钥重新配置 Agent 终端。'
          '新密钥仅在此刻展示一次，请立即保存。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              try {
                final newKey = await ref
                    .read(agentListProvider.notifier)
                    .rotateSecretKey(agent.id);
                if (context.mounted) _showNewSecretDialog(context, newKey);
              } catch (e) {
                if (context.mounted) {
                  showAppSnackBar(
                    context,
                    '重置失败: $e',
                    type: SnackBarType.error,
                  );
                }
              }
            },
            child: const Text('确定重置'),
          ),
        ],
      ),
    );
  }

  /// 新密钥一次性展示:可选中密文 + 复制 + 「我已保存」关闭。
  void _showNewSecretDialog(BuildContext context, String newKey) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新密钥(仅展示一次)'),
        content: _NewSecretContent(secretKey: newKey),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('我已保存'),
          ),
        ],
      ),
    );
  }

  /// 删除 Agent:确认 → 删除 + 联动移除消息列表相关会话 → 回万灵页。
  void _delete(BuildContext context, WidgetRef ref, Agent agent) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('删除 ${agent.name} 后将无法恢复，且相关会话也会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFFA5151),
            ),
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              try {
                await ref.read(agentListProvider.notifier).delete(agent.id);
                ref
                    .read(conversationProvider.notifier)
                    .removeByAgentId(agent.id);
                if (context.mounted) context.go('/wanling');
              } catch (e) {
                if (context.mounted) {
                  showAppSnackBar(
                    context,
                    '删除失败: $e',
                    type: SnackBarType.error,
                  );
                }
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

/// 类型徽标:''→普通 / hermes→Hermes / opencode→OpenCode。
class _TypeBadge extends StatelessWidget {
  final String type;

  const _TypeBadge({required this.type});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = switch (type) {
      AgentCategory.hermes => 'Hermes',
      AgentCategory.opencode => 'OpenCode',
      _ => '普通',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: scheme.primary,
        ),
      ),
    );
  }
}

/// AppID 行:label + 可选中 monospace 文本 + 复制按钮(「已复制」切换)。
class _AppIdRow extends StatefulWidget {
  final String value;

  const _AppIdRow({required this.value});

  @override
  State<_AppIdRow> createState() => _AppIdRowState();
}

class _AppIdRowState extends State<_AppIdRow> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          'AppID',
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SelectableText(
            widget.value,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
        IconButton(
          icon: Icon(
            _copied ? Icons.check : Icons.copy,
            size: 16,
            color: _copied
                ? scheme.primary
                : scheme.onSurface.withValues(alpha: 0.5),
          ),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: widget.value));
            setState(() => _copied = true);
          },
        ),
        if (_copied)
          Text(
            '已复制',
            style: TextStyle(fontSize: 12, color: scheme.primary),
          ),
      ],
    );
  }
}

/// 操作行:图标 + 文案,点击进对应弹窗(删除红色)。
class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    required this.label,
    this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effective = color ?? scheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(
              icon,
              size: 17,
              color: color ?? effective.withValues(alpha: 0.7),
            ),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(fontSize: 13, color: effective)),
          ],
        ),
      ),
    );
  }
}

/// 新密钥展示内容:密文(可选中) + 复制按钮(「已复制」切换)。
class _NewSecretContent extends StatefulWidget {
  final String secretKey;

  const _NewSecretContent({required this.secretKey});

  @override
  State<_NewSecretContent> createState() => _NewSecretContentState();
}

class _NewSecretContentState extends State<_NewSecretContent> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            widget.secretKey,
            style: const TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            IconButton(
              icon: Icon(
                _copied ? Icons.check : Icons.copy,
                size: 18,
                color: scheme.primary,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.secretKey));
                setState(() => _copied = true);
              },
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? '已复制' : '复制',
              style: TextStyle(fontSize: 13, color: scheme.primary),
            ),
          ],
        ),
      ],
    );
  }
}
