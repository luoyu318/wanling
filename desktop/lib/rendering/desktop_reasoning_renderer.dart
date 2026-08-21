import 'package:flutter/material.dart';

import 'package:wanling_core/utils/duration_format.dart';
import 'package:wanling_core/utils/icon_font.dart';
import 'package:wanling_core/widgets/markdown_config.dart';
import 'package:wanling_core/widgets/markdown_view.dart';

/// 桌面版思考块:分叉自 core ReasoningRenderer 终态卡(desktop 聚合卡
/// 内使用)。交互差异:去尾部 ▸,hover 时前导思考 icon 切换成展开指示
/// (chevron),鼠标离开恢复——静态视觉干净,可点性靠 hover 发现。
/// 点击行为与 core 一致:弹底部抽屉看全文(抽屉实现复制自 core
/// _showDetail,markdown 渲染复用 core 组件)。
class DesktopReasoningCard extends StatefulWidget {
  final String text;
  final num? duration;

  const DesktopReasoningCard({super.key, this.text = '', this.duration});

  @override
  State<DesktopReasoningCard> createState() => _DesktopReasoningCardState();
}

class _DesktopReasoningCardState extends State<DesktopReasoningCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: () => _showDetail(context, widget.text),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 15,
                height: 15,
                child: Center(
                  child: _hovering
                      ? const Icon(Icons.chevron_right,
                          size: 15, color: Color(0xFFD4A017))
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
                  style:
                      const TextStyle(fontSize: 14, color: Color(0xFF999999)),
                ),
              ),
              // 桌面版:尾部 ▸ 移除(可点性靠 hover 前导 icon 表达)。
            ],
          ),
        ),
      ),
    );
  }

  String _foldedText() {
    final d = widget.duration;
    if (d is num && d > 0) {
      return '思考完成 · ${formatDurationMs(d.toInt())}';
    }
    return '思考完成';
  }
}

void _showDetail(BuildContext context, String text) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
    builder: (ctx) => Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              decoration: BoxDecoration(
                  color: const Color(0xFFDDDDDD),
                  borderRadius: BorderRadius.circular(2)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                IconFont.icon(IconFont.deepThink,
                    size: 18, color: const Color(0xFFD4A017)),
                const SizedBox(width: 6),
                const Text('思考',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF333333))),
              ]),
            ),
            const Divider(height: 1, color: Color(0xFFEEEEEE)),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: MarkdownView(
                  data: text,
                  config: markdownStyle(isDark: false, isMe: false, context: ctx),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
