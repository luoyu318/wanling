import 'package:flutter/material.dart';
import 'package:app/models/quote.dart';

/// 输入框引用预览条(V1 卡片式)。
/// 用户长按消息选「引用」后,在输入框上方显示被引用消息的预览。
/// 视觉风格与 MessageQuoteBlock(B1 紧凑左竖线)一致,但略大 + 带关闭按钮。
class QuotePreviewBar extends StatelessWidget {
  final Quote quote;
  final VoidCallback onCancel;

  const QuotePreviewBar({
    super.key,
    required this.quote,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x1A597BFF),
        borderRadius: BorderRadius.circular(3),
        border: Border(
          left: BorderSide(color: const Color(0xFF597BFF), width: 2),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  quote.senderName,
                  style: const TextStyle(
                    color: Color(0xFF597BFF),
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  quote.preview,
                  style: const TextStyle(color: Color(0xFF555555), fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onCancel,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.close,
                size: 12,
                color: Colors.black54,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
