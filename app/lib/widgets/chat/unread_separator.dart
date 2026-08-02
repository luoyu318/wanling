import 'package:flutter/material.dart';

/// 未读消息分隔线。
/// 显示在第一条未读消息上方，文案"以下是新消息"（不带数量——数量由蓝色浮标承担）。
/// 普通非粘性（随列表滚动）。
class UnreadSeparator extends StatelessWidget {
  const UnreadSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: const [
          Expanded(
              child: Divider(color: Color(0xFFB0B0B0), thickness: 0.5)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '以下是新消息',
              style: TextStyle(
                color: Color(0xFF888888),
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
              child: Divider(color: Color(0xFFB0B0B0), thickness: 0.5)),
        ],
      ),
    );
  }
}
