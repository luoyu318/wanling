import 'package:flutter/material.dart';

/// 对话压缩分割线。
///
/// plugin streamer 在用户触发 /compact 后,通过 compact_divider 消息插入。
/// 3 态:
///   running — 3 点呼吸动画 + 正在压缩对话历史 + 3 点呼吸动画
///   done    — ✓ 上下文压缩完成
///   failed  — ⚠ 压缩失败(红字)
///
/// 设计参考 UnreadSeparator:Padding + Row[Expanded Divider, 内容, Expanded Divider]。
/// 非粘性,随列表滚动。
class CompactDivider extends StatefulWidget {
  final String phase;

  const CompactDivider({super.key, required this.phase});

  @override
  State<CompactDivider> createState() => _CompactDividerState();
}

class _CompactDividerState extends State<CompactDivider>
    with TickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = widget.phase == 'running';
    final isFailed = widget.phase == 'failed';

    final text = isRunning
        ? '正在压缩对话历史'
        : (isFailed ? '压缩失败' : '上下文压缩完成');
    final color = isFailed ? const Color(0xFFE57373) : const Color(0xFF888888);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          const Expanded(child: Divider(color: Color(0xFFB0B0B0), thickness: 0.5)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isRunning) _BreathingDots(controller: _controller),
                if (isRunning) const SizedBox(width: 6),
                if (!isRunning)
                  Icon(
                    isFailed ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                    size: 14,
                    color: color,
                  ),
                if (!isRunning) const SizedBox(width: 6),
                Text(
                  text,
                  style: TextStyle(color: color, fontSize: 12),
                ),
                if (isRunning) ...[
                  const SizedBox(width: 6),
                  _BreathingDots(controller: _controller),
                ],
              ],
            ),
          ),
          const Expanded(child: Divider(color: Color(0xFFB0B0B0), thickness: 0.5)),
        ],
      ),
    );
  }
}

/// 3 个圆点呼吸动画(running 态用)。
/// _controller 在 parent 里 repeat,这里只读 Animation<double>。
class _BreathingDots extends StatelessWidget {
  final AnimationController controller;

  const _BreathingDots({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // 3 个点错相相位 0/0.33/0.66
            final t = (controller.value + i / 3) % 1.0;
            final opacity = 0.3 + 0.7 * (1 - (t - 0.5).abs() * 2);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Opacity(
                opacity: opacity.clamp(0.3, 1.0),
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                    color: Color(0xFF888888),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
