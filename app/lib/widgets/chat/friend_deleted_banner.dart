import 'package:flutter/material.dart';

/// dm_user_user 删除好友后顶部提示条幅。
class FriendDeletedBanner extends StatelessWidget {
  const FriendDeletedBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFFFF7E6),
      padding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 10,
      ),
      child: const Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 16,
            color: Color(0xFFFA8C16),
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              '已不是好友,无法发送消息',
              style: TextStyle(
                fontSize: 13,
                color: Color(0xFF874D00),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
