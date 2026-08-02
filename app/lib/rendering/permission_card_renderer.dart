import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/msg_type.dart';
import '../providers/auth_provider.dart' show apiProvider;
import '../utils/snackbar.dart';
import 'message_content_renderer.dart';
import 'truncatable_text_block.dart';

/// 弹出权限审批底部抽屉。
///
/// 公共入口：被 [PermissionCardRenderer]（独立审批卡渲染）和
/// `_PendingApprovalChip`（task 卡片下挂的审批缩略条）共用。
/// sheet widget [_PermissionReplySheet] 保持私有。
void showPermissionReplySheet(
  BuildContext context, {
  required String convId,
  required String ocRequestId,
  required String action,
  required List<String> resources,
  required Map<String, dynamic> metadata,
  required List<String> save,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (ctx) => _PermissionReplySheet(
      convId: convId,
      ocRequestId: ocRequestId,
      action: action,
      resources: resources,
      metadata: metadata,
      save: save,
    ),
  );
}

/// 权限审批卡片渲染器。
///
/// 渲染 OpenCode 发起的权限请求（bash/edit/write 等动作需用户授权）。
/// - pending：暖色（琥珀）卡片，点击弹出底部抽屉，用户选「仅本次 / 始终 / 拒绝」
///   后发 permission_reply 消息。plugin 收到后 PATCH 原卡片切终态，APP 收
///   MESSAGE_UPDATE 重新渲染（build 读 content['data']['status']，自然切终态）。
/// - approved/denied：终态卡片，灰阶 + 结果摘要 + 半透明，不可再操作。
///
/// wrapInBubble=false（自带卡片外壳，类似 FileCard / FileDiff）；
/// selectable=true（与 FileDiff 一致，卡片内文字可被外层 SelectableRegion 选中）。
///
/// 无超时：与 OpenCode TUI 行为一致，pending 无限期保持，直到 APP 或 TUI 端处理。
class PermissionCardRenderer implements MessageContentRenderer {
  const PermissionCardRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'] as Map<String, dynamic>? ?? {};
    final status = data['status'] as String? ?? 'pending';
    final action = data['action'] as String? ?? '';
    final resources = (data['resources'] as List?)?.cast<String>() ?? [];
    final save = (data['save'] as List?)?.cast<String>() ?? [];
    final metadata = data['metadata'] as Map<String, dynamic>? ?? {};
    final ocRequestId = data['oc_request_id'] as String? ?? '';
    final result = data['result'] as String?;

    final isTerminal = status == 'approved' || status == 'denied' || status == 'expired';
    if (isTerminal) {
      return _TerminalPermissionCard(
        action: action,
        resources: resources,
        metadata: metadata,
        status: status,
        result: result,
      );
    }

    return _PendingPermissionCard(
      action: action,
      resources: resources,
      metadata: metadata,
      onTap: () => showPermissionReplySheet(
        context,
        convId: rc.convId,
        ocRequestId: ocRequestId,
        action: action,
        resources: resources,
        metadata: metadata,
        save: save,
      ),
    );
  }
}

/// permission 规则名 → 中文标签。
String _permissionLabel(String action) {
  const labels = {
    'bash': '执行命令',
    'edit': '编辑文件',
    'write': '写入文件',
    'read': '读取文件',
    'glob': '搜索文件名',
    'grep': '搜索内容',
    'list': '列出目录',
    'task': '子任务',
    'external_directory': '访问外部目录',
    'webfetch': '访问网络',
    'lsp': '语言服务',
    'skill': '技能调用',
  };
  return labels[action] ?? action;
}

/// 从 metadata + resources 提取具体操作内容（命令/路径）。
/// 优先 metadata.command（bash），其次 metadata.filepath（文件操作），兜底 resources[0]。
String? _permissionDetail(Map<String, dynamic> metadata, List<String> resources) {
  final command = metadata['command'];
  if (command is String && command.isNotEmpty) return command;
  final filepath = metadata['filepath'];
  if (filepath is String && filepath.isNotEmpty) return filepath;
  if (resources.isNotEmpty) return resources.first;
  return null;
}

/// pending 卡片：琥珀边框 + 动作/资源摘要 + 「点击处理」提示。
class _PendingPermissionCard extends StatelessWidget {
  final String action;
  final List<String> resources;
  final Map<String, dynamic> metadata;
  final VoidCallback onTap;

  const _PendingPermissionCard({
    required this.action,
    required this.resources,
    required this.metadata,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final label = _permissionLabel(action);
    final detail = _permissionDetail(metadata, resources);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.95),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7E6),
          borderRadius: BorderRadius.circular(8),
          border: const Border(left: BorderSide(color: Color(0xFFFA8C16), width: 3)),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  '权限审批 · $label',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFB45F06),
                  ),
                ),
              ],
            ),
            if (detail != null) ...[
              const SizedBox(height: 4),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Color(0xFF8C5A1A),
                ),
              ),
            ],
            const SizedBox(height: 6),
            const Align(
              alignment: Alignment.centerRight,
              child: Text(
                '点击处理 →',
                style: TextStyle(fontSize: 11, color: Color(0xFFFA8C16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 终态卡片：绿/红背景 + 结果摘要 + 半透明，不可操作。
class _TerminalPermissionCard extends StatelessWidget {
  final String action;
  final List<String> resources;
  final Map<String, dynamic> metadata;
  final String status;
  final String? result;

  const _TerminalPermissionCard({
    required this.action,
    required this.resources,
    required this.metadata,
    required this.status,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final approved = status == 'approved';
    final expired = status == 'expired';
    // 设计稿三态：approved=绿，denied=红，expired=灰
    final accent = expired
        ? const Color(0xFF757575)
        : approved
            ? const Color(0xFF2E7D32)
            : const Color(0xFFC62828);
    final bgColor = expired
        ? const Color(0xFFF5F5F5)
        : approved
            ? const Color(0xFFE8F5E9)
            : const Color(0xFFFFEBEE);
    final label = _permissionLabel(action);
    final detail = _permissionDetail(metadata, resources);
    final resultText = expired
        ? '会话已结束'
        : approved
            ? (result == 'always' ? '已批准（始终）' : '已批准（仅本次）')
            : '已拒绝';
    return Opacity(
      opacity: 0.75,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.95),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  '权限审批 · $label',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ],
            ),
            if (detail != null) ...[
              const SizedBox(height: 4),
              TruncatableTextBlock(
                text: detail,
                sheetTitle: Text('权限审批 · $label'),
                textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFF666666)),
                backgroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              ),
            ],
            const SizedBox(height: 4),
            Text(
              resultText,
              style: TextStyle(fontSize: 12, color: accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// 回复底部抽屉：action/resources 详情 + 三选项 radio + save 规则只读展示 + 确认按钮。
///
/// 确认后发 permission_reply（silent:true）。成功关抽屉，等 MESSAGE_UPDATE 重渲染；
/// 失败弹错误 snackbar，保留抽屉让用户重试。
class _PermissionReplySheet extends ConsumerStatefulWidget {
  final String convId;
  final String ocRequestId;
  final String action;
  final List<String> resources;
  final Map<String, dynamic> metadata;
  final List<String> save;

  const _PermissionReplySheet({
    required this.convId,
    required this.ocRequestId,
    required this.action,
    required this.resources,
    required this.metadata,
    required this.save,
  });

  @override
  ConsumerState<_PermissionReplySheet> createState() => _PermissionReplySheetState();
}

class _PermissionReplySheetState extends ConsumerState<_PermissionReplySheet> {
  /// 'once' | 'always' | 'reject'，未选为 null（确认按钮禁用）。
  String? _choice;
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: (mq.size.height - mq.viewInsets.bottom) * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('⚡', style: TextStyle(fontSize: 20)),
                      const SizedBox(width: 8),
                      const Text(
                        '权限审批',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF333333),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFFF3E0),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          '待处理',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFFE65100),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Agent 请求执行以下操作，需要你的授权',
                    style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '动作',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF999999),
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _permissionLabel(widget.action),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Color(0xFF333333),
                      ),
                    ),
                    ...() {
                      final detail = _permissionDetail(widget.metadata, widget.resources);
                      if (detail == null) return <Widget>[];
                      return [
                        const SizedBox(height: 16),
                        const Text(
                          '内容',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xFF999999),
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF263238),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            detail,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                              height: 1.6,
                              color: Color(0xFF80CBC4),
                            ),
                          ),
                        ),
                      ];
                    }(),
                    const SizedBox(height: 20),
                    _PermissionOption(
                      value: 'once',
                      groupValue: _choice,
                      accentColor: const Color(0xFF4CAF50),
                      label: '仅本次允许',
                      description: '允许执行这一次',
                      onChanged: _sending ? null : _onChoice,
                    ),
                    const SizedBox(height: 10),
                    _PermissionOption(
                      value: 'always',
                      groupValue: _choice,
                      accentColor: const Color(0xFF7C5CE7),
                      label: '始终允许',
                      description: '保存规则，以后不再询问',
                      onChanged: _sending ? null : _onChoice,
                      expanded: (_choice == 'always' && widget.save.isNotEmpty)
                          ? _SaveRules(rules: widget.save)
                          : null,
                    ),
                    const SizedBox(height: 10),
                    _PermissionOption(
                      value: 'reject',
                      groupValue: _choice,
                      accentColor: const Color(0xFFEF5350),
                      label: '拒绝',
                      description: '阻止此次执行',
                      isDanger: true,
                      onChanged: _sending ? null : _onChoice,
                    ),
                  ],
                ),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
              ),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_choice == null || _sending) ? null : _onConfirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF597BFF),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor:
                        const Color(0xFF597BFF).withValues(alpha: 0.4),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text(
                          '确认',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onChoice(String v) => setState(() => _choice = v);

  Future<void> _onConfirm() async {
    if (_choice == null || _sending) return;
    final reply = _choice!;
    setState(() => _sending = true);
    try {
      final content = <String, dynamic>{
        'msg_type': MsgType.permissionReply.value,
        // silent:true — 控制类消息，不计未读、不注入 prompt（plugin SyncEngine 过滤）。
        'silent': true,
        'data': <String, dynamic>{
          'oc_request_id': widget.ocRequestId,
          'reply': reply,
        },
      };
      await ref.read(apiProvider).sendMessage(widget.convId, content);
      if (mounted) Navigator.of(context).pop();
      // 成功后不本地切终态：等 plugin PATCH → MESSAGE_UPDATE 由 chatProvider
      // 替换 content → 本 renderer.build 读 status 自然切终态。
    } catch (e) {
      if (mounted) {
        setState(() => _sending = false);
        showAppSnackBar(context, '提交失败，请重试', type: SnackBarType.error);
      }
    }
  }
}

/// 权限选项 card：圆形 radio 指示器 + 标题 + 描述，选中时展开 [expanded]（save 规则）。
class _PermissionOption extends StatelessWidget {
  final String value;
  final String? groupValue;
  final Color accentColor;
  final String label;
  final String description;
  final Widget? expanded;
  final bool isDanger;
  final ValueChanged<String>? onChanged;

  const _PermissionOption({
    required this.value,
    required this.groupValue,
    required this.accentColor,
    required this.label,
    required this.description,
    this.expanded,
    this.isDanger = false,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final selected = value == groupValue;
    return InkWell(
      onTap: onChanged == null ? null : () => onChanged!(value),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(
            color: selected ? accentColor : const Color(0xFFDDDDDD),
            width: selected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? accentColor : const Color(0xFFCCCCCC),
                      width: 2,
                    ),
                    color: selected ? accentColor : Colors.transparent,
                  ),
                  alignment: Alignment.center,
                  child: selected
                      ? const Icon(Icons.check, size: 12, color: Colors.white)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color:
                              isDanger ? const Color(0xFFEF5350) : const Color(0xFF333333),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF888888),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (selected && expanded != null) ...[
              const SizedBox(height: 12),
              expanded!,
            ],
          ],
        ),
      ),
    );
  }
}

/// save 规则只读展示：选「始终允许」时在选项内部展开。
/// 每条规则一行，紫色底标签 + emoji；含通配符的危险规则红色标注。
class _SaveRules extends StatelessWidget {
  final List<String> rules;

  const _SaveRules({required this.rules});

  bool _isDangerous(String rule) {
    final trimmed = rule.trim();
    if (trimmed.endsWith('/*') || trimmed.endsWith('*')) return true;
    if (trimmed.contains('/*') && !trimmed.contains('/tmp/')) return true;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0xFFF0F0F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            '📋 选择"始终允许"将自动保存以下规则：',
            style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
          ),
          const SizedBox(height: 8),
          ...rules.map((r) {
            final dangerous = _isDangerous(r);
            return Container(
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF3E5F5),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Text(dangerous ? '⚠️' : '📄',
                      style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: dangerous
                            ? const Color(0xFFEF5350)
                            : const Color(0xFF333333),
                      ),
                    ),
                  ),
                  if (dangerous)
                    const Text(
                      '危险范围',
                      style: TextStyle(fontSize: 11, color: Color(0xFFEF5350)),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
