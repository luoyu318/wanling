import 'package:flutter/material.dart';

/// 动作菜单项：竖排菜单的一行（icon 左 + 文字右）。
/// [color] 用于危险操作（如删除）标红，默认深黑。
class ActionMenuItem {
  final String value;
  final String label;
  final IconData icon;
  final Color? color;

  const ActionMenuItem({
    required this.value,
    required this.label,
    required this.icon,
    this.color,
  });
}

/// 菜单锚点对齐方式。
enum AppMenuAlign {
  /// 菜单左上角对齐锚点(长按按压点)。
  topLeft,

  /// 菜单右上角对齐锚点 x(按钮右缘),顶部在锚点下方 8px(右对齐下拉,不遮按钮)。
  belowRight,
}

/// 通用竖排动作菜单（白底圆角 + 菜单项 icon）。
///
/// 长按 / 按钮触发的统一动作列表样式：
/// - 白底、圆角 8、轻阴影，无分隔线
/// - 每项 icon 左 + 文字右，高 48，危险项用 [ActionMenuItem.color] 标红
/// - 按 [align] 决定对齐：topLeft 左上角对齐 [globalPos]；belowRight 右上角贴
///   [globalPos].dx 且顶部在其下方 8px；均带屏幕边缘保护（8px 边距不溢出）
///
/// 返回选中的 [ActionMenuItem.value]；点击空白处返回 null。
/// 弹出用 PageRouteBuilder(Duration.zero) 无动画，全屏 GestureDetector 点空白关闭。
Future<String?> showAppActionMenu(
  BuildContext context,
  Offset globalPos, {
  required List<ActionMenuItem> items,
  AppMenuAlign align = AppMenuAlign.topLeft,
}) async {
  final overlay = Navigator.of(context).overlay!;
  final overlayBox = overlay.context.findRenderObject() as RenderBox;
  final overlaySize = overlayBox.size;
  final local = overlayBox.globalToLocal(globalPos);

  const menuItemHeight = 48.0;
  const menuWidth = 160.0;
  final menuHeight = menuItemHeight * items.length;

  final double left;
  double top;
  if (align == AppMenuAlign.belowRight) {
    left = (local.dx - menuWidth < 8) ? 8 : local.dx - menuWidth;
    top = local.dy + 8;
    if (top + menuHeight > overlaySize.height - 8) {
      top = overlaySize.height - menuHeight - 8;
    }
  } else {
    left = (local.dx + menuWidth > overlaySize.width - 8)
        ? overlaySize.width - menuWidth - 8
        : local.dx;
    top = (local.dy + menuHeight > overlaySize.height - 8)
        ? overlaySize.height - menuHeight - 8
        : local.dy;
  }

  return Navigator.of(context).push<String>(
    PageRouteBuilder<String>(
      opaque: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (ctx, _, _) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(ctx),
          child: Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    key: const ValueKey('app-action-menu'),
                    width: menuWidth,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 12,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final item in items)
                          _menuItem(item: item, onTap: () {
                            Navigator.pop(ctx, item.value);
                          }),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}

Widget _menuItem({
  required ActionMenuItem item,
  required VoidCallback onTap,
}) {
  final color = item.color ?? const Color(0xFF111111);
  return InkWell(
    onTap: onTap,
    child: Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Icon(item.icon, size: 20, color: color),
          const SizedBox(width: 12),
          Text(item.label, style: TextStyle(color: color, fontSize: 14)),
        ],
      ),
    ),
  );
}
