import 'package:flutter/material.dart';

/// 聊天页内的「跳转到底部」浮标（圆形）。
///
/// 显示条件：unreadCount == 0 && !_isAtBottom
/// （由 ChatPage build 内 Positioned 的 if 条件控制）
///
/// 与未读浮标（胶囊样式）形成视觉区分，主流 IM 同款。
class JumpToBottomButton extends StatelessWidget {
  final VoidCallback onTap;

  const JumpToBottomButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(
            Icons.keyboard_arrow_down,
            color: Colors.black87,
            size: 28,
          ),
        ),
      ),
    );
  }
}
