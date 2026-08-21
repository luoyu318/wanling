import 'package:flutter/material.dart';

import 'package:wanling_core/models/slash_command.dart' show SlashCommand;
import 'package:wanling_core/utils/mono_font.dart';

import 'panel_scroll.dart';

/// 桌面 slash 命令面板:列出过滤后命令(name + 描述),↑↓ 高亮 / Enter/点击选中。
///
/// 由 DesktopInputBar 经 OverlayEntry 渲染在输入框上方;
/// 本组件只管展示与交互回调,过滤/高亮状态由父级持有。
///
/// 滚动跟随策略(防 hover 连环滚动):hover 改高亮**永不**触发滚动;
/// 仅父级在键盘 ↑↓ 导航时调 [followHighlight](最小滚动跟随),
/// 过滤结果变化时 jumpTo 保持高亮项可见(无动画)。
class SlashPanel extends StatefulWidget {
  final List<SlashCommand> commands;
  final int highlightedIndex;
  final ValueChanged<int> onHover;
  final ValueChanged<SlashCommand> onSelected;

  const SlashPanel({
    super.key,
    required this.commands,
    required this.highlightedIndex,
    required this.onHover,
    required this.onSelected,
  });

  @override
  State<SlashPanel> createState() => SlashPanelState();
}

class SlashPanelState extends State<SlashPanel> {
  final List<GlobalKey> _itemKeys = [];

  @override
  void didUpdateWidget(SlashPanel old) {
    super.didUpdateWidget(old);
    // 仅过滤结果变化(列表长度/实例变)时校正滚动,hover 高亮变化不滚。
    if (old.commands != widget.commands) {
      _scheduleReveal(animate: false);
    }
  }

  /// 键盘导航入口:最小滚动跟随高亮项(可见即不动)。
  void followHighlight() => _scheduleReveal(animate: true);

  void _scheduleReveal({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final idx = widget.highlightedIndex;
      if (idx < 0 || idx >= _itemKeys.length) return;
      final ctx = _itemKeys[idx].currentContext;
      if (ctx != null) revealItemMinimal(ctx, animate: animate);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _itemKeys.clear();
    for (var i = 0; i < widget.commands.length; i++) {
      _itemKeys.add(GlobalKey());
    }
    return _PanelSurface(
      panelKey: const ValueKey('slash_panel'),
      child: ListView.builder(
        shrinkWrap: true,
        padding: const EdgeInsets.all(4),
        itemCount: widget.commands.length,
        itemBuilder: (context, i) {
          final cmd = widget.commands[i];
          return _PanelItem(
            itemKey: ValueKey('slash_panel_item_${cmd.name}'),
            highlightKey: i == widget.highlightedIndex ? _itemKeys[i] : null,
            highlighted: i == widget.highlightedIndex,
            onHover: () => widget.onHover(i),
            onTap: () => widget.onSelected(cmd),
            child: Row(
              children: [
                Text(
                  '/${cmd.name}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace', fontFamilyFallback: kMonoFontFallback,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    cmd.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  cmd.source == 'skill' ? '技能' : '命令',
                  style: TextStyle(
                    fontSize: 10,
                    color: scheme.onSurface.withValues(alpha: 0.35),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 面板公共外壳:毛玻璃风格的 Material 卡片 + 限高限宽。
class _PanelSurface extends StatelessWidget {
  final Key panelKey;
  final Widget child;

  const _PanelSurface({required this.panelKey, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      key: panelKey,
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: scheme.surface,
      surfaceTintColor: scheme.surface,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 288, maxWidth: 400),
        child: child,
      ),
    );
  }
}

/// 面板行:hover 更新高亮,点击/高亮态着色。
class _PanelItem extends StatelessWidget {
  final Key itemKey;
  final GlobalKey? highlightKey;
  final bool highlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;
  final Widget child;

  const _PanelItem({
    required this.itemKey,
    required this.highlighted,
    required this.onHover,
    required this.onTap,
    required this.child,
    this.highlightKey,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // ValueKey 挂 Container(唯一,供测试/查找);高亮时 InkWell 挂 GlobalKey
    // 供 ensureVisible 拿 context。两个 key 不同对象,避免 find 双匹配。
    return InkWell(
      key: highlighted ? highlightKey : null,
      onTap: onTap,
      onHover: (_) => onHover(),
      child: Container(
        key: itemKey,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: highlighted
              ? scheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: child,
      ),
    );
  }
}
