import 'package:flutter/material.dart';
import 'package:app/models/quote.dart';

/// 引用块 widget(B1 紧凑左竖线样式)。
/// 显示被引用消息的 sender + preview,放在气泡上方(独立结构,与气泡同级)。
class MessageQuoteBlock extends StatelessWidget {
  final Quote quote;
  final bool isRevoked; // 被引用消息是否已撤回/删除(本地状态)
  final VoidCallback? onTap;

  const MessageQuoteBlock({
    super.key,
    required this.quote,
    this.isRevoked = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0x1A597BFF), // 浅紫底(主题色 10% alpha)
          borderRadius: BorderRadius.circular(3),
          border: Border(
            left: BorderSide(color: const Color(0xFF597BFF), width: 2),
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // sender 行(主题色 + 600 字重 + 9px,Agent 加紫色智能体标)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    quote.senderName,
                    style: const TextStyle(
                      color: Color(0xFF597BFF),
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (quote.senderType == 'agent') ...[
                  const SizedBox(width: 3),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 3, vertical: 0),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDE9FE),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: const Text(
                      '智能体',
                      style: TextStyle(
                        color: Color(0xFF6D28D9),
                        fontSize: 7,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            // preview 行(9px + 灰色 + 单行省略;isRevoked 时显示「原消息已撤回」)
            Text(
              isRevoked ? '原消息已撤回' : quote.preview,
              style: TextStyle(
                color: isRevoked
                    ? const Color(0xFF999999)
                    : const Color(0xFF555555),
                fontSize: 9,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
