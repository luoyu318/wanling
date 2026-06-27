import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_menu_style.dart';

/// 估算的菜单宽度（4 个中文按钮 + 3 条 0.5px 分隔线）。
///
/// SDK 的 TextSelectionToolbarLayout 把 menu 中心对齐 anchorAbove 后再
/// clamp 到屏幕内。三角水平位置 = anchorX - menuLeft - tailW/2，需要 menu
/// 宽度。实际宽度 220-260 浮动，这里固定 250 估算，误差 5-10px 对三角视觉
/// 影响可忽略。
const _tailWidth = 10.0;
const _tailHeight = 6.0;
const _safeEdgePadding = 8.0;
const _menuItemHPadding = 28.0; // TextSelectionToolbarTextButton horizontal 14*2
const _menuDividerWidth = 0.5;

/// 文字级选区菜单（深色胶囊 + 自定义圆角/阴影）。
///
/// 用 [TextSelectionToolbar] 直接构造（绕开 AdaptiveTextSelectionToolbar 的
/// buttonItems 自动模式），通过 [toolbarBuilder] 自定义容器外观：
/// - 背景 [AppMenuStyle.darkBg]
/// - 圆角 [AppMenuStyle.radiusFloating]
/// - 阴影 [AppMenuStyle.shadow]
/// - 项之间 0.5px 分隔线
///
/// 处理策略：
/// - 白名单只保留 cut/copy/paste/selectAll（过滤 custom/share 等）
/// - label 为 null/空时按 type 查硬编码中文 label 兜底
/// - children 用 [TextSelectionToolbarTextButton]（SDK 默认按钮样式）
class AppTextSelectionToolbar extends StatelessWidget {
  final List<ContextMenuButtonItem> buttonItems;
  final TextSelectionToolbarAnchors anchors;

  const AppTextSelectionToolbar({
    super.key,
    required this.buttonItems,
    required this.anchors,
  });

  @override
  Widget build(BuildContext context) {
    const allowedTypes = {
      ContextMenuButtonType.cut,
      ContextMenuButtonType.copy,
      ContextMenuButtonType.paste,
      ContextMenuButtonType.selectAll,
    };

    final validItems = buttonItems
        .where((item) => allowedTypes.contains(item.type))
        .map((item) {
          final rawLabel = item.label;
          final label = (rawLabel != null && rawLabel.isNotEmpty)
              ? rawLabel
              : _defaultLabelForType(item.type);
          if (label.isEmpty) return null;
          return (item: item, label: label);
        })
        .whereType<({ContextMenuButtonItem item, String label})>()
        .toList(growable: false);

    if (validItems.isEmpty) return const SizedBox.shrink();

    // 三角水平位置：跟随选区中心（anchorAbove.dx），并按 SDK 的 clamp 行为
    // 估算 menu 左边。menuW 用 TextPainter 按真实 label 测量，避免 2 项/4 项
    // 宽度差异大时三角与菜单错位。
    // 三角水平位置：跟随选区中心（anchorAbove.dx），并按 SDK 的 clamp 行为
    // 估算 menu 左边。menuW 用 TextPainter 按真实 label 测量，避免 2 项/4 项
    // 宽度差异大时三角与菜单错位。tailLeft clamp 到圆角内（左右各留 radius=8），
    // 防止三角落在 Container 圆角弧线区域产生细缝。
    final menuW = _measureMenuWidth(context, validItems);
    final anchorX = anchors.primaryAnchor.dx;
    final screenW = MediaQuery.sizeOf(context).width;
    final menuLeft = (anchorX - menuW / 2).clamp(
      _safeEdgePadding,
      math.max(_safeEdgePadding, screenW - menuW - _safeEdgePadding),
    );
    final tailMin = AppMenuStyle.radiusFloating;
    final tailMax = math.max(tailMin, menuW - _tailWidth - AppMenuStyle.radiusFloating);
    final tailLeft = (anchorX - menuLeft - _tailWidth / 2).clamp(tailMin, tailMax);

    // children 渲染：button + 分隔线交替
    final children = <Widget>[];
    for (var i = 0; i < validItems.length; i++) {
      final e = validItems[i];
      children.add(
        TextSelectionToolbarTextButton(
          onPressed: e.item.onPressed,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Text(e.label),
        ),
      );
      if (i < validItems.length - 1) {
        children.add(
          Container(
            width: 0.5,
            margin: const EdgeInsets.symmetric(vertical: 8),
            color: AppMenuStyle.darkDivider,
          ),
        );
      }
    }

    return Theme(
      // 子树覆盖 onSurface 让按钮文字色变白（surface 已在 toolbarBuilder 控制）
      data: Theme.of(context).copyWith(
        colorScheme: Theme.of(context).colorScheme.copyWith(
              onSurface: AppMenuStyle.darkFg,
            ),
      ),
      child: TextSelectionToolbar(
        anchorAbove: anchors.primaryAnchor,
        anchorBelow: anchors.secondaryAnchor ?? anchors.primaryAnchor,
        toolbarBuilder: (context, child) => Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: BoxDecoration(
                color: AppMenuStyle.darkBg,
                borderRadius: BorderRadius.circular(AppMenuStyle.radiusFloating),
                boxShadow: const [AppMenuStyle.shadow],
              ),
              child: Material(
                color: Colors.transparent,
                type: MaterialType.transparency,
                child: child,
              ),
            ),
            // 底部三角朝下指向选区，水平位置跟随选区中心（tailLeft）。
            // bottom=-5 + height=6 让三角顶部嵌入 Container 底部 1px，
            // 防抗锯齿在三角顶与 Container 底之间留细缝。
            Positioned(
              bottom: -5,
              left: tailLeft,
              child: CustomPaint(
                size: const Size(_tailWidth, _tailHeight),
                painter: _TailPainter(
                  color: AppMenuStyle.darkBg,
                  pointDown: true,
                ),
              ),
            ),
          ],
        ),
        children: children,
      ),
    );
  }
}

/// 按 type 返回硬编码中文 label（不依赖 MaterialLocalizations）。
String _defaultLabelForType(ContextMenuButtonType type) {
  switch (type) {
    case ContextMenuButtonType.cut:
      return '剪切';
    case ContextMenuButtonType.copy:
      return '复制';
    case ContextMenuButtonType.paste:
      return '粘贴';
    case ContextMenuButtonType.selectAll:
      return '全选';
    case ContextMenuButtonType.lookUp:
      return '查询';
    case ContextMenuButtonType.searchWeb:
      return '搜索';
    case ContextMenuButtonType.share:
      return '分享';
    case ContextMenuButtonType.delete:
      return '删除';
    case ContextMenuButtonType.liveTextInput:
    case ContextMenuButtonType.custom:
      return '';
  }
}

/// 用 TextPainter 按真实 label 测量菜单宽度。
///
/// 替代固定估算值（如 250px），避免 2 项 vs 4 项时菜单实际宽度差异大导致
/// 三角和菜单错位。字号取 theme.textTheme.labelLarge（TextButton 默认），
/// 水平 padding 按 TextSelectionToolbarTextButton 传入的 14*2=28。
double _measureMenuWidth(
  BuildContext context,
  List<({ContextMenuButtonItem item, String label})> items,
) {
  final style = Theme.of(context).textTheme.labelLarge ?? const TextStyle();
  double total = 0;
  for (final e in items) {
    final tp = TextPainter(
      text: TextSpan(text: e.label, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    total += tp.width + _menuItemHPadding;
    tp.dispose();
  }
  if (items.length > 1) {
    total += (items.length - 1) * _menuDividerWidth;
  }
  return total;
}

/// 菜单底部三角指示器（指向选区）。
///
/// pointDown=true 顶点朝下（菜单在选区上方时用），false 朝上（菜单在下方）。
/// 实现参考 message_context_menu.dart 的 _MenuTailPainter。
class _TailPainter extends CustomPainter {
  final Color color;
  final bool pointDown;

  const _TailPainter({required this.color, required this.pointDown});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path();
    if (pointDown) {
      path.moveTo(size.width / 2, size.height);
      path.lineTo(0, 0);
      path.lineTo(size.width, 0);
    } else {
      path.moveTo(size.width / 2, 0);
      path.lineTo(0, size.height);
      path.lineTo(size.width, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TailPainter old) =>
      color != old.color || pointDown != old.pointDown;
}
