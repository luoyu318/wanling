import 'package:flutter/material.dart';

import 'message_content_renderer.dart';
import 'subagent_renderer.dart';
import 'tool_card_body_widgets.dart';
import 'truncatable_text_block.dart';

/// 工具调用渲染器：按 data.name 分派到 per-tool 子 widget。
/// task → SubagentBody，其余 → 对应工具卡片。
class ToolCallRenderer implements MessageContentRenderer {
  const ToolCallRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(BuildContext context, Map<String, dynamic> content, MessageRenderContext rc) {
    final data = content['data'] as Map<String, dynamic>? ?? {};
    final name = (data['name'] as String?) ?? '';
    final input = (data['input'] as Map<String, dynamic>?) ?? {};

    final body = _buildToolBody(name, input, context, isDark: rc.isDark);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        // 深色卡底沿用既定色板 26272D,浅色逐字不变
        color: rc.isDark ? const Color(0xFF26272D) : const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: Color(0xFF5B8BF7), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(capitalize(name), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: rc.isDark ? const Color(0xFFEEEEEE) : const Color(0xFF111111))),
          if (body != null) ...[
            const SizedBox(height: 6),
            body,
          ],
        ],
      ),
    );
  }

  Widget? _buildToolBody(String name, Map<String, dynamic> input, BuildContext context, {required bool isDark}) {
    return switch (name) {
      'bash' => BashBody(input: input, isDark: isDark),
      'edit' => EditBody(input: input, isDark: isDark),
      'read' => ReadBody(input: input, isDark: isDark),
      'grep' => GrepBody(input: input, isDark: isDark),
      'glob' => GlobBody(input: input, isDark: isDark),
      'todowrite' => TodoBody(input: input, isDark: isDark),
      'write' => WriteBody(input: input, isDark: isDark),
      'task' => SubagentBody(input: input, isDark: isDark),
      _ => input.isNotEmpty
          ? TruncatableTextBlock(
              text: input.toString(),
              sheetTitle: Text(capitalize(name)),
              textStyle: TextStyle(fontFamily: 'monospace', fontSize: 11, color: isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666)),
              maxLines: 1,
            )
          : null,
    };
  }
}


