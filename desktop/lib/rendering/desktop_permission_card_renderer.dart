import 'package:flutter/material.dart';

import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/rendering/permission_card_renderer.dart';
import 'package:wanling_core/rendering/truncatable_text_block.dart';
import 'package:wanling_core/utils/mono_font.dart';

/// 桌面版权限卡渲染器:分叉自 core PermissionCardRenderer(desktop 启动时
/// 覆盖注册)。差异仅在终态折叠外壳——去尾部常驻箭头,hover 标题行时
/// 前导结果 icon 切换成展开指示(与折叠组/思考块同套 hover 语言)。
/// pending 卡直接委托 core 版;终态展开内容为本地终态原卡(样式复制自
/// core _TerminalPermissionCard,其为私有无法复用)。
class DesktopPermissionCardRenderer implements MessageContentRenderer {
  const DesktopPermissionCardRenderer();

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
    final isTerminal =
        status == 'approved' || status == 'denied' || status == 'expired';
    // pending 卡无折叠交互,委托 core 原版。
    if (!isTerminal) {
      return const PermissionCardRenderer().build(context, content, rc);
    }
    final action = data['action'] as String? ?? '';
    final resources = (data['resources'] as List?)?.cast<String>() ?? [];
    final metadata = data['metadata'] as Map<String, dynamic>? ?? {};
    final result = data['result'] as String?;
    return _DesktopPermissionTerminalFold(
      action: action,
      resources: resources,
      metadata: metadata,
      status: status,
      result: result,
      rc: rc,
    );
  }
}

/// 桌面版终态折叠外壳:标题行 hover 切前导 icon,点击原地展开完整终态
/// 原卡。滚动补偿同构 core 折叠组。
class _DesktopPermissionTerminalFold extends StatefulWidget {
  final String action;
  final List<String> resources;
  final Map<String, dynamic> metadata;
  final String status;
  final String? result;
  final MessageRenderContext rc;

  const _DesktopPermissionTerminalFold({
    required this.action,
    required this.resources,
    required this.metadata,
    required this.status,
    required this.result,
    required this.rc,
  });

  @override
  State<_DesktopPermissionTerminalFold> createState() =>
      _DesktopPermissionTerminalFoldState();
}

class _DesktopPermissionTerminalFoldState
    extends State<_DesktopPermissionTerminalFold> {
  bool _expanded = false;
  bool _hovering = false;

  final GlobalKey _key = GlobalKey();
  final GlobalKey _contentKey = GlobalKey();

  void _toggle() {
    final contentHeight = _contentKey.currentContext?.size?.height ?? 0;
    final delta = _expanded ? contentHeight : -contentHeight;
    setState(() => _expanded = !_expanded);
    widget.rc.onToolGroupToggle
        ?.call(_key, _expanded, delta, widget.rc.isHistorySliver);
  }

  @override
  Widget build(BuildContext context) {
    final approved = widget.status == 'approved';
    final expired = widget.status == 'expired';
    final accent = expired
        ? const Color(0xFF757575)
        : approved
            ? const Color(0xFF2E7D32)
            : const Color(0xFFC62828);
    final label = _label(widget.action);
    final resultText = expired
        ? '会话已结束'
        : approved
            ? (widget.result == 'always' ? '已批准（始终）' : '已批准（仅本次）')
            : '已拒绝';
    return Padding(
      key: _key,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: InkWell(
              onTap: _toggle,
              child: Row(
                children: [
                  // 前导 icon:hover 切展开指示,非 hover 恢复结果 icon。
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: Center(
                      child: _hovering
                          ? Icon(
                              _expanded
                                  ? Icons.keyboard_arrow_down
                                  : Icons.chevron_right,
                              size: 15,
                              color: accent,
                            )
                          : Icon(
                              expired
                                  ? Icons.timelapse
                                  : approved
                                      ? Icons.check_circle_outline
                                      : Icons.cancel_outlined,
                              size: 15,
                              color: accent,
                            ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '权限审批 · $label',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF555555)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(resultText,
                      style: TextStyle(fontSize: 12, color: accent)),
                  // 桌面版:尾部常驻箭头移除。
                ],
              ),
            ),
          ),
          // 展开内容:终态原卡(样式同 core _TerminalPermissionCard)。
          ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: _expanded ? 1.0 : 0.0,
              child: Padding(
                key: _contentKey,
                padding: const EdgeInsets.only(top: 6),
                child: _TerminalCard(
                  action: widget.action,
                  resources: widget.resources,
                  metadata: widget.metadata,
                  status: widget.status,
                  result: widget.result,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 终态原卡(样式复制自 core _TerminalPermissionCard,私有无法直接复用)。
class _TerminalCard extends StatelessWidget {
  final String action;
  final List<String> resources;
  final Map<String, dynamic> metadata;
  final String status;
  final String? result;

  const _TerminalCard({
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
    final label = _label(action);
    final detail = _detail(metadata, resources);
    final resultText = expired
        ? '会话已结束'
        : approved
            ? (result == 'always' ? '已批准（始终）' : '已批准（仅本次）')
            : '已拒绝';
    return Opacity(
      opacity: 0.75,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.95),
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
            Text(
              '权限审批 · $label',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(height: 4),
              TruncatableTextBlock(
                text: detail,
                sheetTitle: Text('权限审批 · $label'),
                textStyle: const TextStyle(
                    fontFamily: 'monospace',
                    fontFamilyFallback: kMonoFontFallback,
                    fontSize: 12,
                    color: Color(0xFF666666)),
                backgroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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

/// 权限规则名 → 中文标签(与 core _permissionLabel 同表,core 为私有)。
String _label(String action) {
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

/// metadata + resources 提取操作内容(与 core _permissionDetail 同逻辑)。
String? _detail(Map<String, dynamic> metadata, List<String> resources) {
  final command = metadata['command'];
  if (command is String && command.isNotEmpty) return command;
  final filepath = metadata['filepath'];
  if (filepath is String && filepath.isNotEmpty) return filepath;
  if (resources.isNotEmpty) return resources.first;
  return null;
}
