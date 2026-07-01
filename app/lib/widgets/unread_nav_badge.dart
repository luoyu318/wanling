import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// 聊天页内的未读消息导航浮标（统一胶囊）。
/// 仅当 ChatState.unreadCount > 0 且不在底部时显示（由 ChatPage build 内 Positioned 控制）。
/// 合并历史未读 + 会话内新消息计数。点击跳到最新消息并标记已读。
class UnreadNavBadge extends StatelessWidget {
  final int count;
  final VoidCallback onTap;

  const UnreadNavBadge({
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
            color: AppColors.accentGreen,
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
              const Icon(Icons.keyboard_arrow_down,
                  color: Colors.white, size: 18),
              const SizedBox(width: 4),
              Text(
                '$count 条新消息',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
