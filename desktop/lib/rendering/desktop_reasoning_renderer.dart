import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/utils/duration_format.dart';
import 'package:wanling_core/utils/icon_font.dart';
import 'package:wanling_core/widgets/markdown_config.dart';
import 'package:wanling_core/widgets/markdown_view.dart';

/// 桌面版思考块:分叉自 core ReasoningRenderer 终态卡(desktop 聚合卡
/// 内使用)。交互差异:
/// - 去尾部 ▸,hover 标题行时前导思考 icon 切换成展开指示(chevron);
/// - 点击改为聚合卡内原地展开全文(core 为弹底部抽屉,桌面大屏无需抽屉),
///   展开结构同折叠组(Align(heightFactor) 始终渲染 + 滚动补偿)。
class DesktopReasoningCard extends StatefulWidget {
  final String text;
  final num? duration;
  final MessageRenderContext? rc;

  const DesktopReasoningCard(
      {super.key, this.text = '', this.duration, this.rc});

  @override
  State<DesktopReasoningCard> createState() => _DesktopReasoningCardState();
}

class _DesktopReasoningCardState extends State<DesktopReasoningCard> {
  bool _expanded = false;
  bool _hovering = false;

  final GlobalKey _key = GlobalKey();
  final GlobalKey _contentKey = GlobalKey();

  void _toggle() {
    final contentHeight = _contentKey.currentContext?.size?.height ?? 0;
    final delta = _expanded ? contentHeight : -contentHeight;
    setState(() => _expanded = !_expanded);
    widget.rc?.onToolGroupToggle?.call(
        _key, _expanded, delta, widget.rc?.isHistorySliver ?? false);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovering = true),
          onExit: (_) => setState(() => _hovering = false),
          child: InkWell(
            onTap: _toggle,
            child: Padding(
              key: _key,
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 15,
                    height: 15,
                    child: Center(
                      // hover 切展开指示,方向跟随展开态(与折叠组同语言):
                      // 未展开右指(可展开)/已展开下指(可收起)。
                      child: _hovering
                          ? Icon(
                              _expanded
                                  ? Icons.keyboard_arrow_down
                                  : Icons.chevron_right,
                              size: 15,
                              color: const Color(0xFFD4A017),
                            )
                          : IconFont.icon(IconFont.deepThink,
                              size: 15, color: const Color(0xFFD4A017)),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _foldedText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, color: Color(0xFF999999)),
                    ),
                  ),
                  // 桌面版:尾部 ▸ 移除(hover 前导 icon 表达可点性)。
                ],
              ),
            ),
          ),
        ),
        // 原地展开全文:整体浅灰(思考内容不抢正文视觉)——纯文本走灰 Text,
        // markdown 思考链(常见 **强调**/`代码`)段落色替换为浅灰(标题/链接
        // 等富元素保持,降饱和但不丢可读性)。
        ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: _expanded ? 1.0 : 0.0,
            child: Padding(
              key: _contentKey,
              padding: const EdgeInsets.only(top: 6, bottom: 6),
              child: _hasMarkdownSyntax(widget.text)
                  ? MarkdownView(
                      data: widget.text,
                      config: _mutedMarkdownConfig(context),
                    )
                  : Text(
                      widget.text,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFFAAAAAA), height: 1.5),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  String _foldedText() {
    final d = widget.duration;
    if (d is num && d > 0) {
      return '思考完成 · ${formatDurationMs(d.toInt())}';
    }
    return '思考完成';
  }

  /// markdown 语法检测(正则与 core TextContentRenderer 同款,私有无法复用)。
  static final _markdownRe = RegExp(
    r'(^|\n)\s{0,3}(#{1,6}\s|[*+-]\s|\d+\.\s|>)'
    r'|```'
    r'|`[^`]+`'
    r'|\*\*[^*]+\*\*'
    r'|\*[^*]+\*'
    r'|_[^_]+_'
    r'|\[[^\]]+\]\([^)]+\)'
    r'|\$[^$\n]+\$',
  );

  static bool _hasMarkdownSyntax(String text) =>
      text.isNotEmpty && _markdownRe.hasMatch(text);

  /// 降饱和 markdown config:基于 core markdownStyle,copy 按 tag 覆盖
  /// 段落(PConfig)字色为浅灰 #AAAAAA(其余配置原样),思考整体退后于正文。
  static MarkdownConfig _mutedMarkdownConfig(BuildContext context) {
    return markdownStyle(isDark: false, isMe: false, context: context).copy(
      configs: const [
        PConfig(
          textStyle:
              TextStyle(fontSize: 13, color: Color(0xFFAAAAAA), height: 1.5),
        ),
      ],
    );
  }
}
