import 'package:flutter/material.dart';

import '../utils/emoji_span.dart';
import 'message_content_renderer.dart';

class SlashEchoRenderer implements MessageContentRenderer {
  const SlashEchoRenderer();

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'];
    final display = (data?['display'] as String?) ?? '';
    final slashName = (data?['_slash']?['name'] as String?) ?? '';
    if (display.isEmpty) return const SizedBox.shrink();

    final bubbleColor = const Color(0xFF597BFF);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (slashName.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(right: 4, bottom: 2),
            child: Text(
              '/$slashName',
              style: const TextStyle(fontSize: 10, color: Color(0xFF7C5CE7)),
            ),
          ),
        Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(5),
          ),
          child: buildEmojiColoredText(
            display,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}
