import 'package:flutter/material.dart';

import 'message_content_renderer.dart';
import 'truncatable_text_block.dart';

/// 工具结果渲染器：紧凑白底卡片。
/// 短输出直接显示，长输出截断 + 点击弹出底部抽屉查看全文。
class ToolResultRenderer implements MessageContentRenderer {
  const ToolResultRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(BuildContext context, Map<String, dynamic> content, MessageRenderContext rc) {
    final data = content['data'] as Map<String, dynamic>? ?? {};
    final name = (data['name'] as String?) ?? '';
    final output = (data['output'] as String?) ?? '';
    final isSubagent = name == 'task';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: Color(0xFF07C160), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(capitalize(name), style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: isSubagent ? const Color(0xFF5856D6) : const Color(0xFF111111),
              )),
              const Spacer(),
              const Text('完成', style: TextStyle(fontSize: 11, color: Color(0xFF07C160))),
            ],
          ),
          if (output.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            if (output.length <= 80)
              Text(output, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF07C160)))
            else
              TruncatableTextBlock(
                text: output,
                sheetTitle: Text(capitalize(name), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
                textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF666666)),
                maxLines: 1,
              ),
          ],
        ],
      ),
    );
  }
}

