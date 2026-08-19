import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'select_all_container.dart';

/// markdown_widget 代码块的外层包装:右上角复制按钮,点击复制代码,图标 ✓ 2 秒回弹。
/// 不显示语言标签(生产方向:只复制+高亮,不要语言标签)。
///
/// 代码块内部是高亮 TextSpan(可选),外层包 [SelectAllOrNoneContainer] 实现
/// "拉杆碰到代码块即整块选中"(主流 IM 式)。复制时拿到的是 [code] 纯文本。
///
/// 签名刻意对齐 markdown_widget 的 CodeWrapper typedef
/// (Widget Function(Widget child, String code, String language)),
/// 可直接传给 PreConfig(wrapper: markdownCodeWrapper)。
Widget markdownCodeWrapper(Widget child, String code, String language) {
  // code 作为 fallbackText:代码块内高亮 TextSpan 天然可选，fallbackText 仅在
  // 极端情况(高亮 widget 完全不含可选文本)兜底，不影响正常行为。
  return _CodeWrapper(code: code, child: child);
}

class _CodeWrapper extends StatefulWidget {
  final Widget child;
  final String code;
  const _CodeWrapper({required this.child, required this.code});

  @override
  State<_CodeWrapper> createState() => _CodeWrapperState();
}

class _CodeWrapperState extends State<_CodeWrapper> {
  bool _copied = false;

  Future<void> _copy() async {
    if (_copied) return;
    await Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // SelectAllOrNoneContainer: 拉杆碰到代码块整块选中(主流 IM 式)。
    // Stack(代码内容 + 复制按钮)作为 child，代码 TextSpan 参与选择。
    return SelectAllOrNoneContainer(
      fallbackText: widget.code,
      child: Stack(
        children: [
          widget.child,
          Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: InkWell(
                onTap: _copy,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Icon(
                    _copied ? Icons.check : Icons.copy_rounded,
                    key: ValueKey(_copied),
                    size: 18,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
