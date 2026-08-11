import 'package:flutter/material.dart';

import 'message_content_renderer.dart';
import 'truncatable_text_block.dart';

/// 工具错误渲染器：浅红底 + 左红边框。
class ToolErrorRenderer implements MessageContentRenderer {
  const ToolErrorRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(BuildContext context, Map<String, dynamic> content, MessageRenderContext rc) {
    final data = content['data'] as Map<String, dynamic>? ?? {};
    final name = (data['name'] as String?) ?? '';
    final error = (data['error'] as String?) ?? '';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF5F5),
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: Color(0xFFFA5151), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text('❌ ', style: TextStyle(fontSize: 13)),
              Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111111))),
              const Spacer(),
              const Text('失败', style: TextStyle(fontSize: 11, color: Color(0xFFFA5151))),
            ],
          ),
          if (error.isNotEmpty) ...[
            const SizedBox(height: 4),
            TruncatableTextBlock(
              text: error,
              sheetTitle: const Text('执行失败'),
              textStyle: const TextStyle(fontSize: 12, color: Color(0xFFFA5151)),
              backgroundColor: Colors.transparent,
              padding: EdgeInsets.zero,
              maxLines: 1,
            ),
          ],
        ],
      ),
    );
  }
}
