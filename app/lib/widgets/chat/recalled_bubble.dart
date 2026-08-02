import 'package:flutter/material.dart';

/// 撤回消息占位。dm 场景按 isMe 切「你/对方撤回了一条消息」。
/// 居中灰色文字,无气泡外壳,与正常气泡视觉区分(已非实际消息内容)。
///
/// 文案优先级:isMe →「你撤回了一条消息」(单聊/群聊一致);
/// 否则 isGroup + 有 senderName →「${senderName} 撤回了一条消息」;
/// 否则 →「对方撤回了一条消息」。
/// senderName 仅群聊非自己撤回时需要,单聊场景 isMe 切「你/对方」即可。
class RecalledBubble extends StatelessWidget {
  final bool isMe;
  final bool isGroup;
  final String? senderName;

  const RecalledBubble({
    super.key,
    required this.isMe,
    this.isGroup = false,
    this.senderName,
  });

  @override
  Widget build(BuildContext context) {
    final text = isMe
        ? '你撤回了一条消息'
        : (isGroup && (senderName?.isNotEmpty ?? false)
              ? '$senderName 撤回了一条消息'
              : '对方撤回了一条消息');
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          text,
          style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
        ),
      ),
    );
  }
}
