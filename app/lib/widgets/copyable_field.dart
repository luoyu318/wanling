import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/snackbar.dart';

/// 一行展示 label + value，trailing 是复制 icon（secret 时再加眼睛 icon）。
/// IM 风：label 灰色小字 + value 黑色 + 复制按钮。
class CopyableField extends StatefulWidget {
  final String label;
  final String value;
  final bool secret;

  const CopyableField({
    super.key,
    required this.label,
    required this.value,
    this.secret = false,
  });

  @override
  State<CopyableField> createState() => _CopyableFieldState();
}

class _CopyableFieldState extends State<CopyableField> {
  bool _obscured = true;

  // 掩码显示：secret 模式下默认遮蔽，眼睛切换后明文。
  String get _displayValue {
    if (!widget.secret) return widget.value;
    return _obscured ? '•' * widget.value.length : widget.value;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.value));
    if (mounted) {
      showAppSnackBar(context, '已复制', type: SnackBarType.success);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(widget.label, style: const TextStyle(fontSize: 13, color: Color(0xFF999999))),
          ),
          Expanded(
            child: Text(
              _displayValue,
              style: const TextStyle(fontSize: 14, color: Color(0xFF111111), fontFamily: 'monospace'),
            ),
          ),
          if (widget.secret)
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(_obscured ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18, color: const Color(0xFF999999)),
              onPressed: () => setState(() => _obscured = !_obscured),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy_outlined, size: 18, color: Color(0xFF576B95)),
            onPressed: _copy,
          ),
        ],
      ),
    );
  }
}
