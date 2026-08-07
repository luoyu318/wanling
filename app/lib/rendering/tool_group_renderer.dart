import 'package:flutter/material.dart';

import '../models/msg_type.dart';
import 'message_content_renderer.dart';

/// 聚合卡元素分派槽位:单个非折叠元素(平铺)或一组同类工具(折叠)。
/// 公开类型:renderer + 单测跨文件访问需要。
sealed class ElementSlot {
  const ElementSlot();
}

/// 单个元素(非折叠):reasoning/markdown/footer/compact_divider/交互卡/task 卡。
class SingleElementSlot extends ElementSlot {
  final Map<String, dynamic> element;
  const SingleElementSlot(this.element);
}

/// 一组同类工具(折叠)。
class ToolGroupSlot extends ElementSlot {
  final List<Map<String, dynamic>> cards;
  const ToolGroupSlot(this.cards);
}

/// 折叠类别:探索(read/grep/glob)/命令(bash)/编辑(edit/write)。
/// 对齐 opencode `CONTEXT_GROUP_TOOLS` 扩展:官方折叠 read/glob/grep/list,
/// 我们扩展 bash(命令)与 edit/write(编辑)也按同类折叠。
enum ToolCategory { explore, command, edit }

/// tool_card.data.name → 折叠类别;不折叠的返回 null。
ToolCategory? categoryOfTool(Map<String, dynamic> card) {
  final name = ((card['data'] as Map?)?['name'] as String?) ?? '';
  switch (name) {
    case 'read':
    case 'glob':
    case 'grep':
      return ToolCategory.explore;
    case 'bash':
      return ToolCategory.command;
    case 'edit':
    case 'write':
      return ToolCategory.edit;
    default:
      return null; // webfetch/task/todowrite 及未知工具不折叠
  }
}

/// 是否隐藏(对齐官方 HIDDEN_TOOLS,只隐藏 todowrite)。
bool isHiddenTool(Map<String, dynamic> card) =>
    ((card['data'] as Map?)?['name'] as String?) == 'todowrite';

/// 分组器(纯函数):把聚合卡平铺 elements 按「折叠类别 + 连续性」切组。
///
/// 对齐 opencode `groupParts`:同一折叠类别的工具物理连续(中间无任何
/// 其他元素)合并成同一折叠组;类别切换即拆组;单条也折叠(N=1)。
/// 隐藏工具(todowrite)直接跳过;平铺元素(reasoning/markdown/footer/
/// compact_divider/交互卡/task/webfetch)单独成 SingleElementSlot。
List<ElementSlot> groupAggregateElements(List<Map<String, dynamic>> elements) {
  final slots = <ElementSlot>[];
  var group = <Map<String, dynamic>>[];
  var groupCategory = ToolCategory.explore;
  void flush() {
    if (group.isNotEmpty) {
      slots.add(ToolGroupSlot(group));
      group = [];
    }
  }

  for (final e in elements) {
    if (e['type'] != 'tool_card') {
      flush();
      slots.add(SingleElementSlot(e));
      continue;
    }
    if (isHiddenTool(e)) continue; // todowrite 隐藏
    final category = categoryOfTool(e);
    if (category == null) {
      flush();
      slots.add(SingleElementSlot(e)); // webfetch/task/未知 平铺
      continue;
    }
    // 新组:以当前工具类别为组类别;否则若类别不同则拆组
    if (group.isEmpty) {
      group = [e];
      groupCategory = category;
    } else if (category == groupCategory) {
      group.add(e);
    } else {
      flush();
      group = [e];
      groupCategory = category;
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
