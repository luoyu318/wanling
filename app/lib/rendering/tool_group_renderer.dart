import 'package:flutter/material.dart';

import '../models/msg_type.dart';
import 'message_content_renderer.dart';

/// 聚合卡元素分派槽位:单个非 tool_card 元素(平铺)或一组连续 tool_card(折叠)。
/// 公开类型:renderer + 单测跨文件访问需要。
sealed class ElementSlot {
  const ElementSlot();
}

/// 单个元素(非折叠):reasoning/markdown/footer/compact_divider/交互卡/task 卡。
class SingleElementSlot extends ElementSlot {
  final Map<String, dynamic> element;
  const SingleElementSlot(this.element);
}

/// 一组连续 tool_card(折叠)。
class ToolGroupSlot extends ElementSlot {
  final List<Map<String, dynamic>> cards;
  const ToolGroupSlot(this.cards);
}

/// 分组器(纯函数):把聚合卡平铺 elements 按「连续 tool_card」切组。
///
/// 规则:
/// - 物理连续(中间无任何其他元素)的 tool_card 合并为一组
/// - task 子 agent 卡(name=='task')不参与折叠,单独成 Slot
/// - permission_card / question_card 不折叠,单独成 Slot
/// - 单个 tool_card 也成 ToolGroupSlot(N=1),用同一折叠组件
List<ElementSlot> groupAggregateElements(List<Map<String, dynamic>> elements) {
  final slots = <ElementSlot>[];
  var group = <Map<String, dynamic>>[];
  void flush() {
    if (group.isNotEmpty) {
      slots.add(ToolGroupSlot(group));
      group = [];
    }
  }

  for (final e in elements) {
    final type = e['type'] as String?;
    final isTool = type == 'tool_card';
    final isTaskTool = isTool && (e['data'] as Map?)?['name'] == 'task';
    if (isTool && !isTaskTool) {
      group.add(e);
    } else {
      flush();
      slots.add(SingleElementSlot(e));
    }
  }
  flush();
  return slots;
}

/// 折叠工具卡:收起一行「⚡ 工具调用 · N」,点击展开组内每个 tool_card(复用现有渲染)。
/// [rc] 为外层聚合卡的 MessageRenderContext,展开渲染时透传(isStreaming/baseUrl/
/// rootMessageId 等保持一致)。
class ToolGroupCard extends StatefulWidget {
  final List<Map<String, dynamic>> cards;
  final MessageRenderContext rc;
  const ToolGroupCard({super.key, required this.cards, required this.rc});

  @override
  State<ToolGroupCard> createState() => _ToolGroupCardState();
}

class _ToolGroupCardState extends State<ToolGroupCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFEEEEEE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            child: Row(
              children: [
                const Text('⚡ ', style: TextStyle(fontSize: 12)),
                Expanded(
                  child: Text(
                    '工具调用 · ${widget.cards.length}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF666666)),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: const Color(0xFFBBBBBB),
                ),
              ],
            ),
          ),
          if (_expanded)
            for (final e in widget.cards)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ContentRendererRegistry.render(
                  MsgType.toolCard,
                  <String, dynamic>{
                    'msg_type': MsgType.toolCard.value,
                    'data': e['data'],
                  },
                  context,
                  widget.rc,
                ),
              ),
        ],
      ),
    );
  }
}
