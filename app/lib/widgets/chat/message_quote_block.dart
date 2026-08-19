import 'package:flutter/material.dart';
import 'package:wanling_core/models/quote.dart';

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
        // 单行布局:@昵称 [智能体] : preview(省略号截断)。
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                '@${quote.senderName}',
                style: const TextStyle(
                  color: Color(0xFF597BFF),
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Agent 加紫色智能体小标(单行内联保留身份标识)
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
            const SizedBox(width: 3),
            // preview 单行(9px + 灰色;isRevoked 时显示「原消息已撤回」)
            Expanded(
              child: Text(
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
            ),
          ],
        ),
      ),
    );
  }
}
