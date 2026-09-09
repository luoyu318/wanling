import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:app/widgets/avatar.dart';

/// 收件箱抽屉来源条：会话头像 + 会话名 + 队列进度 + 右上「暂不处理」。
class InboxSourceHeader extends StatelessWidget {
  final String convId;

  /// 会话显示名（convByIdProvider 查不到时用 convId 前 8 位占位）。
  final String title;

  /// 标题回填监听（agent_session 等不在列表 state 的会话，经
  /// getConversation 异步单查后刷新名字）；null 时静态展示 [title]。
  final ValueListenable<String>? titleListenable;

  /// 会话头像 URL（可空，Avatar 组件内部降级首字）。
  final String? avatarUrl;

  /// 队列进度「n / total」。
  final int index;
  final int total;

  /// 右上「暂不处理」回调。
  final VoidCallback onDefer;

  const InboxSourceHeader({
    super.key,
    required this.convId,
    required this.title,
    this.titleListenable,
    this.avatarUrl,
    required this.index,
    required this.total,
    required this.onDefer,
  });

  @override
  Widget build(BuildContext context) {
    // 标题行：有回填监听则响应式刷新（异步单查回来后名字上屏）。
    final Widget titleText = titleListenable == null
        ? _titleText(title)
        : ValueListenableBuilder<String>(
            valueListenable: titleListenable!,
            builder: (_, name, _) => _titleText(name),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 9, 12, 9),
      child: Row(
        children: [
          Avatar(name: title, url: avatarUrl, size: 26, radius: 13),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                titleText,
                const Text(
                  'Agent 会话',
                  style: TextStyle(fontSize: 10, color: Color(0xFF999999)),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFF0EDFF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$index / $total',
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Color(0xFF7C4DFF),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onDefer,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              foregroundColor: const Color(0xFF888888),
            ),
            child: const Text('暂不处理', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _titleText(String name) => Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF222222),
        ),
      );
}
