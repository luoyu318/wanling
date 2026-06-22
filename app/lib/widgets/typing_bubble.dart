import 'package:flutter/material.dart';
import 'message_bubble.dart' show BubbleWithTail;

/// Agent "正在输入..." 加载气泡。
///
/// 用 BubbleWithTail 包一个动画 dots 文本（. → .. → ... 循环）。
/// 显示在消息列表底部 agent 一侧，与 ChatPage AppBar 的"对方正在输入..."
/// 文字同步显示。agent 真实消息到达后由 ChatPage 移除本 widget。
///
/// 动画用 TickerProvider + AnimatedBuilder，1500ms 一个完整周期，
/// 3 帧：第 0-500ms "."、500-1000ms ".."、1000-1500ms "..."。
class TypingBubble extends StatefulWidget {
  const TypingBubble({super.key});

  @override
  State<TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<TypingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<int> _dots;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    // StepTween 把 0..1 进度切成 3 段：返回 1 / 2 / 3 个点
    _dots = StepTween(begin: 1, end: 3).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        child: BubbleWithTail(
          isMe: false,
          child: AnimatedBuilder(
            animation: _dots,
            builder: (_, __) => Text(
              '.' * _dots.value,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
