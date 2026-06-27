import 'package:flutter/material.dart';

/// 通用列表项组件：左 icon + label + 右 trailing（默认 chevron）。
///
/// 从 ProfilePage 的 _ProfileTile 升格为公共组件。保留按下反馈
/// （Listener 立即变色 + InkWell 透明 splash，移动 8px 取消）+
/// 左对齐 54px 分割线（与文字对齐）。
///
/// 视觉规格：icon 22 / 文字 15/w300/#333 / chevron 20/#C0C0C0。
class SettingsTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? labelColor;
  final Color? iconColor;
  final bool showDivider;

  const SettingsTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.labelColor,
    this.iconColor,
    this.showDivider = true,
  });

  @override
  State<SettingsTile> createState() => _SettingsTileState();
}

class _SettingsTileState extends State<SettingsTile> {
  bool _isPressed = false;
  Offset? _downPos;

  void _setPressed(bool v) {
    if (_isPressed == v) return;
    setState(() => _isPressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final tileBg = _isPressed ? const Color(0xFFEDEDED) : Colors.white;
    final trailing = widget.trailing ??
        const Icon(Icons.chevron_right, size: 20, color: Color(0xFFC0C0C0));

    return Listener(
      onPointerDown: (e) {
        _downPos = e.position;
        _setPressed(true);
      },
      onPointerMove: (e) {
        if (_downPos != null && (e.position - _downPos!).distance > 8) {
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
              padding: const EdgeInsets.only(
                  left: 16, right: 10, top: 14, bottom: 14),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: 22,
                    color: widget.iconColor ?? const Color(0xFF333333),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w300,
                        color: widget.labelColor ?? const Color(0xFF333333),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  trailing,
                ],
              ),
            ),
            if (widget.showDivider)
              Container(
                key: const ValueKey('settings-tile-divider'),
                height: 0.5,
                color: Colors.white,
                child: Container(
                  margin: const EdgeInsets.only(left: 54),
                  color: const Color(0xFFE4E4E4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
