import 'package:flutter/material.dart';

/// 流式文本渲染:已稳定段走 mdBuilder(终态 Markdown 渲染),
/// 尾巴段逐字符 alpha 渐显(涟漪式),AnimationController.completed 时 settle。
///
/// [text] 当前累积的完整文本。
/// [mdBuilder] 终态渲染函数(settled 段 + streaming=false 时用)。
/// [streaming] 是否仍在流式输出中。false 时直接走 mdBuilder 无动画。
class StreamingText extends StatefulWidget {
  final String text;
  final Widget Function(String) mdBuilder;
  final bool streaming;

  const StreamingText({
    super.key,
    required this.text,
    required this.mdBuilder,
    required this.streaming,
  });

  @override
  State<StreamingText> createState() => _StreamingTextState();
}

class _StreamingTextState extends State<StreamingText>
    with SingleTickerProviderStateMixin {
  /// 已稳定段长度(settle 过的字符不再参与动画)
  int _settledLength = 0;
  late final AnimationController _ctrl;

  static const int _perCharMs = 18;
  static const double _fadeWidth = 0.35;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this);
    _ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() => _settledLength = widget.text.length);
      }
    });
  }

  @override
  void didUpdateWidget(covariant StreamingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.streaming) {
      _ctrl.stop();
      _settledLength = widget.text.length;
      return;
    }
    final tail = widget.text.length - _settledLength;
    if (tail <= 0) return;
    final durationMs = (tail * _perCharMs).clamp(120, 280).toInt();
    _ctrl.duration = Duration(milliseconds: durationMs);
    _ctrl.forward(from: 0);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.streaming) return widget.mdBuilder(widget.text);

    final settled = widget.text.substring(0, _settledLength);
    final tail = widget.text.substring(_settledLength);
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (settled.isNotEmpty) widget.mdBuilder(settled),
        if (tail.isNotEmpty)
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, _) {
              final progress = _ctrl.value;
              return RichText(
                text: _buildTailSpans(tail, progress, theme),
              );
            },
          ),
      ],
    );
  }

  TextSpan _buildTailSpans(String tail, double progress, ThemeData theme) {
    final children = <TextSpan>[];
    final len = tail.length;
    for (int i = 0; i < len; i++) {
      final charProgress = (progress - i / len * _fadeWidth) / (1 - _fadeWidth);
      final alpha = charProgress.clamp(0.0, 1.0);
      children.add(TextSpan(
        text: tail[i],
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.textTheme.bodyMedium?.color?.withValues(alpha: alpha),
        ),
      ));
    }
    return TextSpan(children: children);
  }
}
