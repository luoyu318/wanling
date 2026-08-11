import 'package:flutter/material.dart';

import '../models/msg_type.dart';
import '../utils/icon_font.dart';
import '../widgets/chat/shimmer_text.dart';
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

/// 分组器(纯函数):把聚合卡平铺 elements 按「折叠类别 + 连续性」切组。
///
/// 对齐 opencode `groupParts`:同一折叠类别的工具物理连续(中间无任何
/// 其他元素)合并成同一折叠组;类别切换即拆组;单条也折叠(N=1)。
/// 平铺元素(reasoning/markdown/footer/compact_divider/交互卡/task/webfetch/
/// todowrite)单独成 SingleElementSlot。
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

/// 折叠组标题:类别前缀(进行中/完成) + 按类别计数(跳过 0 值类别)。
/// 对齐 opencode ToolStatusTitle + AnimatedCountList:探索组「正在探索/已探索」,
/// 命令组「正在执行/已执行」,编辑组「正在编辑/已编辑」。
String groupTitle(ToolGroupSlot slot, bool streaming) {
  var read = 0, search = 0, command = 0, edit = 0;
  for (final c in slot.cards) {
    final name = ((c['data'] as Map?)?['name'] as String?) ?? '';
    if (name == 'read') read++;
    if (name == 'glob' || name == 'grep') search++;
    if (name == 'bash') command++;
    if (name == 'edit' || name == 'write') edit++;
  }
  final prefix = switch (categoryOfTool(slot.cards.first)) {
    ToolCategory.command => streaming ? '正在执行' : '已执行',
    ToolCategory.edit => streaming ? '正在编辑' : '已编辑',
    _ => streaming ? '正在探索' : '已探索',
  };
  final parts = <String>[
    if (read > 0) '$read次读取',
    if (search > 0) '$search次搜索',
    if (command > 0) '$command次命令',
    if (edit > 0) '$edit次编辑',
  ];
  final counts = parts.join(', ');
  return counts.isEmpty ? prefix : '$prefix $counts';
}

/// 折叠工具卡:收起一行类别标题,点击展开组内每个 tool_card(复用现有渲染)。
/// [rc] 为外层聚合卡的 MessageRenderContext,展开渲染时透传(isStreaming/baseUrl/
/// rootMessageId 等保持一致)。标题前缀(正在/已)由 rc.isStreaming 决定。
class ToolGroupCard extends StatefulWidget {
  final List<Map<String, dynamic>> cards;
  final MessageRenderContext rc;
  const ToolGroupCard({super.key, required this.cards, required this.rc});

  @override
  State<ToolGroupCard> createState() => _ToolGroupCardState();
}

class _ToolGroupCardState extends State<ToolGroupCard> {
  bool _expanded = false;

  /// 折叠组自身 GlobalKey：展开/收起时上报 ChatPage 做滚动补偿
  /// （history sliver 反向列表下展开内容向上顶，需测高度差校正）。
  /// 挂在外层 Padding 上。
  final GlobalKey _key = GlobalKey();

  /// 展开内容测量 key：内容**始终渲染**（收起时用 Align(heightFactor:0)
  /// 视觉高度为 0 但仍参与布局），同步读取真实高度做滚动补偿，
  /// 避免 postFrame 测新 top 造成的「先渲染再补偿」一帧跳变。
  final GlobalKey _contentKey = GlobalKey();

  /// 展开状态切换并通知外部（ChatPage 做滚动补偿）。
  ///
  /// 同步方案：先读展开内容真实高度（始终渲染可测），算 delta = ±contentHeight
  /// （history 反向：展开 top 上移 contentHeight，收起下移 contentHeight），
  /// setState 与回调同步执行，ChatPage 在同一帧 jumpTo 补偿 → 内容渲染时
  /// offset 已就位，视觉锚点不动、无补间动画、无 postFrame 一帧跳变。
  void _toggle() {
    final contentHeight = _contentKey.currentContext?.size?.height ?? 0;
    // history 反向:展开内容向上长,折叠框 top 上移 contentHeight(delta 负);
    // 收起则下移 contentHeight(delta 正)。
    final delta = _expanded ? contentHeight : -contentHeight;
    setState(() => _expanded = !_expanded);
    widget.rc.onToolGroupToggle
        ?.call(_key, _expanded, delta, widget.rc.isHistorySliver);
  }

  @override
  Widget build(BuildContext context) {
    final streaming = widget.rc.isStreaming;
    final title = groupTitle(ToolGroupSlot(widget.cards), streaming);
    final (icon, iconColor) = _categoryVisual(widget.cards);
    return Padding(
      key: _key,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: _toggle,
            child: Row(
              children: [
                IconFont.icon(icon, size: 15, color: iconColor),
                const SizedBox(width: 6),
                Expanded(
                  child: streaming
                      ? ShimmerText(
                          text: title,
                          baseColor: const Color(0xFF666666),
                          style: const TextStyle(fontSize: 14, color: Color(0xFF666666)),
                        )
                      : Text(
                          title,
                          style: const TextStyle(fontSize: 14, color: Color(0xFF555555)),
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
          // 展开内容始终渲染:Align(heightFactor) 收起时视觉高度 0(不占位)但内容
          // 仍参与布局(_contentKey 可测真实高度),配合同步 jumpTo 补偿零跳变。
          ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              heightFactor: _expanded ? 1.0 : 0.0,
              child: Padding(
                key: _contentKey,
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final e in widget.cards)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 折叠组标题图标 + 颜色(按类别,对齐 mockup 配色)。
(String, Color) _categoryVisual(List<Map<String, dynamic>> cards) {
  final iconColor = switch (categoryOfTool(cards.first)) {
    ToolCategory.command => const Color(0xFF5B8BF7), // 命令组:蓝 shell
    ToolCategory.edit => const Color(0xFF07C160), // 编辑组:绿 编辑
    _ => const Color(0xFFB388FF), // 探索组:紫 搜索
  };
  final icon = switch (categoryOfTool(cards.first)) {
    ToolCategory.command => IconFont.shell,
    ToolCategory.edit => IconFont.edit,
    _ => IconFont.search,
  };
  return (icon, iconColor);
}
