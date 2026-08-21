import 'package:flutter/material.dart';

import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/rendering/tool_group_renderer.dart'
    show groupTitle, ToolGroupSlot, ToolCategory, categoryOfTool;
import 'package:wanling_core/utils/icon_font.dart';
import 'package:wanling_core/widgets/chat/shimmer_text.dart';

/// 桌面版折叠工具组:分叉自 core ToolGroupCard(desktop 聚合卡内使用)。
/// 交互差异:去尾部常驻展开箭头,hover 标题行时前导类别 icon 切换成
/// 展开/收起指示(chevron),鼠标离开恢复类别 icon——静态视觉干净,
/// 可展开性靠 hover 发现(桌面惯例)。
/// 分组/标题/滚动补偿逻辑与 core 版一致。
class DesktopToolGroupCard extends StatefulWidget {
  final List<Map<String, dynamic>> cards;
  final MessageRenderContext rc;
  const DesktopToolGroupCard(
      {super.key, required this.cards, required this.rc});

  @override
  State<DesktopToolGroupCard> createState() => _DesktopToolGroupCardState();
}

class _DesktopToolGroupCardState extends State<DesktopToolGroupCard> {
  bool _expanded = false;
  bool _hovering = false;

  final GlobalKey _key = GlobalKey();
  final GlobalKey _contentKey = GlobalKey();

  void _toggle() {
    final contentHeight = _contentKey.currentContext?.size?.height ?? 0;
    final delta = _expanded ? contentHeight : -contentHeight;
    setState(() => _expanded = !_expanded);
    widget.rc.onToolGroupToggle
        ?.call(_key, _expanded, delta, widget.rc.isHistorySliver);
  }

  @override
  Widget build(BuildContext context) {
    final streaming = widget.rc.isStreaming;
    final shimmerColor =
        widget.rc.isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666);
    final titleColor =
        widget.rc.isDark ? const Color(0xFFC8C8C8) : const Color(0xFF555555);
    final title = groupTitle(ToolGroupSlot(widget.cards), streaming);
    final (icon, iconColor) = _categoryVisual(widget.cards);
    // hover 展开指示色:跟类别 icon 色一致,视觉上「同一个位置换含义」。
    final chevronColor = iconColor;
    return Padding(
      key: _key,
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hovering = true),
            onExit: (_) => setState(() => _hovering = false),
            child: InkWell(
              onTap: _toggle,
              child: Row(
                children: [
                  // 前导 icon:hover 时切展开指示(右指=可展开,下指=可收起),
                  // 非 hover 恢复类别 icon;固定尺寸避免切换时标题跳变。
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: Center(
                      child: _hovering
                          ? Icon(
                              _expanded
                                  ? Icons.keyboard_arrow_down
                                  : Icons.chevron_right,
                              size: 15,
                              color: chevronColor,
                            )
                          : IconFont.icon(icon, size: 15, color: iconColor),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: streaming
                        ? ShimmerText(
                            text: title,
                            baseColor: shimmerColor,
                            style:
                                TextStyle(fontSize: 14, color: shimmerColor),
                          )
                        : Text(
                            title,
                            style:
                                TextStyle(fontSize: 14, color: titleColor),
                          ),
                  ),
                  // 桌面版:尾部常驻箭头移除(展开性靠 hover 前导 icon 表达)。
                ],
              ),
            ),
          ),
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

(String, Color) _categoryVisual(List<Map<String, dynamic>> cards) {
  final iconColor = switch (categoryOfTool(cards.first)) {
    ToolCategory.command => const Color(0xFF5B8BF7),
    ToolCategory.edit => const Color(0xFF07C160),
    _ => const Color(0xFFB388FF),
  };
  final icon = switch (categoryOfTool(cards.first)) {
    ToolCategory.command => IconFont.shell,
    ToolCategory.edit => IconFont.edit,
    _ => IconFont.search,
  };
  return (icon, iconColor);
}
