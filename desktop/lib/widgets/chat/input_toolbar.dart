import 'package:flutter/material.dart';

/// 桌面输入区工具栏(上置):📎 文件 / @ 提及 / / 斜杠 / 🖼️ 图片。
///
/// 纯按钮排,行为由回调注入;[slashEnabled] 控制 / 按钮
/// (slash catalog 仅 agent 会话有,agentId 为 null 时禁用)。
class InputToolbar extends StatelessWidget {
  final VoidCallback onPickFile;
  final VoidCallback onMention;
  final VoidCallback onSlash;
  final VoidCallback onPickImage;
  final bool slashEnabled;

  const InputToolbar({
    super.key,
    required this.onPickFile,
    required this.onMention,
    required this.onSlash,
    required this.onPickImage,
    this.slashEnabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        _ToolbarButton(
          key: const ValueKey('input_toolbar_file'),
          tooltip: '发送文件',
          icon: Icons.attach_file,
          onTap: onPickFile,
        ),
        _ToolbarButton(
          key: const ValueKey('input_toolbar_mention'),
          tooltip: '提及成员 @',
          text: '@',
          onTap: onMention,
        ),
        _ToolbarButton(
          key: const ValueKey('input_toolbar_slash'),
          tooltip: '斜杠命令 /',
          text: '/',
          onTap: slashEnabled ? onSlash : null,
        ),
        _ToolbarButton(
          key: const ValueKey('input_toolbar_image'),
          tooltip: '发送图片',
          icon: Icons.image_outlined,
          onTap: onPickImage,
        ),
        const SizedBox(width: 4),
        // hint:Enter 发送惯例提示,颜色弱化
        Text(
          'Enter 发送 · Shift+Enter 换行',
          style: TextStyle(
            fontSize: 11,
            color: scheme.onSurface.withValues(alpha: 0.35),
          ),
        ),
      ],
    );
  }
}

/// 紧凑工具栏按钮:28×28 圆角 hover 高亮,图标/单字符二选一。
class _ToolbarButton extends StatefulWidget {
  final String tooltip;
  final IconData? icon;
  final String? text;
  final VoidCallback? onTap;

  const _ToolbarButton({
    super.key,
    required this.tooltip,
    required this.onTap,
    this.icon,
    this.text,
  });

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    final color = enabled
        ? scheme.onSurface.withValues(alpha: _hovering ? 0.95 : 0.6)
        : scheme.onSurface.withValues(alpha: 0.25);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hovering = h),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 30,
          height: 26,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovering && enabled
                ? scheme.onSurface.withValues(alpha: 0.06)
                : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: widget.icon != null
              ? Icon(widget.icon, size: 17, color: color)
              : Text(
                  widget.text ?? '',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
        ),
      ),
    );
  }
}
