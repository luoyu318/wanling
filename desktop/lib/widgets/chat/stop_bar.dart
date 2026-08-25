import 'dart:async';
import 'package:flutter/material.dart';

/// agent_session 输入区的常驻停止按钮（紧凑图标款，移植自 app 端 stop_bar）。
///
/// 设计要点：
/// - **始终可见可点击**：不依赖 busy 状态信号（WS 断线 / plugin 重启时状态可能
///   丢失，但实际生成仍在跑，按钮必须随时可触达）。
/// - idle 灰色 / busy 红色高亮，颜色仅作状态提示，两种状态都可点击。
/// - **双击确认**：第一次点击进入"待确认"态（橙色高亮 + "再按一次停止"），
///   3 秒内再次点击才真正触发 onTap；超时自动回到初始态。防误触。
class StopBar extends StatefulWidget {
  final bool isGenerating;
  final VoidCallback onTap;

  const StopBar({
    super.key,
    required this.isGenerating,
    required this.onTap,
  });

  @override
  State<StopBar> createState() => _StopBarState();
}

class _StopBarState extends State<StopBar> {
  bool _armed = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _handleTap() {
    if (!_armed) {
      setState(() => _armed = true);
      _resetTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _armed = false);
      });
      return;
    }
    _resetTimer?.cancel();
    setState(() => _armed = false);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final active = _armed || widget.isGenerating;
    final color = _armed
        ? const Color(0xFFF4A742)
        : (widget.isGenerating ? const Color(0xFFE53935) : const Color(0xFFCCCCCC));
    final textColor = _armed
        ? const Color(0xFFF4A742)
        : (widget.isGenerating ? const Color(0xFFE53935) : const Color(0xFFBBBBBB));

    return GestureDetector(
      onTap: _handleTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(left: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: active ? color : null,
                border: active ? null : Border.all(color: const Color(0xFFDDDDDD), width: 1),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Center(
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: active ? Colors.white : color,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              _armed ? '再按一次' : '停止',
              style: TextStyle(
                fontSize: 12,
                color: textColor,
                fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
