import 'package:flutter/material.dart';

/// 聊天页内的新消息浮标（绿色）。
/// 会话内实时收到新消息且用户不在底部时显示。
/// 与 UnreadNavBadge 互斥：有历史未读时不显示此浮标。
class NewMessageBadge extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const NewMessageBadge({
    super.key,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF07C160), // 万灵品牌绿
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down,
                  color: Colors.white, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
