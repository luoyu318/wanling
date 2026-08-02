import 'package:flutter/material.dart';

import 'message_content_renderer.dart';

/// TUI 用户消息渲染器：紫色气泡 + 上方 via TUI 标签。
///
/// 不走 BubbleWithTail（颜色不同），自建紫色 Container。
/// 通过 ChatPage 的 isMe 覆盖渲染到右侧。
class TuiUserRenderer implements MessageContentRenderer {
  const TuiUserRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(BuildContext context, Map<String, dynamic> content, MessageRenderContext rc) {
    final text = (content['data']?['text'] as String?) ?? '';
    final isMe = rc.isMe;
    final bubbleColor = isMe ? const Color(0xFF597BFF) : Colors.white;
    final textColor = isMe ? Colors.white : const Color(0xFF333333);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.only(right: 4, bottom: 2),
          child: Text(
            '📟 via TUI',
            style: TextStyle(fontSize: 10, color: Color(0xFF7C5CE7)),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            text,
            style: TextStyle(fontSize: 14, color: textColor),
          ),
        ),
      ],
    );
  }
}
