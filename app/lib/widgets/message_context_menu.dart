import 'package:flutter/material.dart';
import '../theme/app_menu_style.dart';

/// 单个菜单项预估宽度(含左右 padding 14×2 + icon 22)。
const double kMenuItemWidth = 50;
/// 菜单容器左右 padding(各 4)。
const double kMenuHPadding = 8;
/// 菜单本体高度(含上下 padding 8×2 + 内容 54)。
const double kMenuHeight = 70;
/// 菜单垂直预算 = 菜单高 + 三角 6 + 间距 8。用于 above/below 判断。
const double kMenuVerticalBudget = 84;
/// 菜单三角尺寸(半宽 5)。
const double kMenuTailHalfWidth = 5;

/// 按 item 数算菜单总宽(用于绝对定位 clamp)。
/// 复制/删除/多选 = 3 项; canRecall=true 时加「撤回」= 4 项。
double menuWidthFor(int itemCount) => kMenuItemWidth * itemCount + kMenuHPadding * 2;

/// 长按消息弹出的浮动菜单(绝对定位,锚钉效果)。
///
/// 设计:
/// - 半透明深色背景(AppMenuStyle.darkBg) + 圆角(AppMenuStyle.radiusAnchor)
///   + 阴影(AppMenuStyle.shadow) + 指向消息的小三角
/// - 默认 3 项: 复制 / 删除 / 多选
/// - canRecall=true 时 4 项: 复制 / 删除 / 撤回 / 多选
///   「删除」常驻(hide,对自己隐藏,per-participant 单向);
///   「撤回」仅在「自己发的 + 5min 内」出现(recall,deleted_at 双向软删)。
/// - 绝对定位(Positioned left/top)而非 CompositedTransformFollower:
///   follower 钉在消息上,消息溢出可见区时菜单跟着溢出。绝对定位让菜单
///   "跟随消息但钉在可见区边缘"——消息在中央时贴消息上方/下方,消息接近
///   AppBar/输入栏时菜单钉在边缘不溢出(IM 式锚钉)。ChatPage 在滚动时
///   重算 left/top 并重建 OverlayEntry。
/// - [tailOffsetX] 三角在菜单内的水平位置(指向消息中心)
/// - [pointDown] 三角朝向:true=朝下(菜单在消息上方),false=朝上
/// - 外部空白用 [Listener](pointer 层)做 tap 判定关闭,不消费拖拽 →
///   弹菜单时仍可上下滑动消息列表
class MessageContextMenu extends StatefulWidget {
  /// 菜单左缘在屏幕的绝对 x(由 ChatPage 算好 clamp 不超屏)。
  final double left;
  /// 菜单顶缘在屏幕的绝对 y(由 ChatPage 算好 clamp 在可见区内)。
  final double top;
  /// 三角在菜单内的水平偏移(指向消息中心)。
  final double tailOffsetX;
  /// 三角朝向:true=朝下(菜单在消息上方),false=朝上。
  final bool pointDown;
  /// 是否显示「撤回」按钮(自己发的 + 5min 内 → true)。
  /// false 时只显示「删除」(对自己隐藏,per-participant)。
  final bool canRecall;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  /// 撤回回调。canRecall=false 时不显示该按钮,但回调本身仍要求传入(代码一致性)。
  final VoidCallback onRecall;
  final VoidCallback onSelect;
  final VoidCallback onDismiss;

  const MessageContextMenu({
    super.key,
    required this.left,
    required this.top,
    this.tailOffsetX = 75,
    this.pointDown = true,
    this.canRecall = false,
    required this.onCopy,
    required this.onDelete,
    required this.onRecall,
    required this.onSelect,
    required this.onDismiss,
  });

  @override
  State<MessageContextMenu> createState() => _MessageContextMenuState();
}

class _MessageContextMenuState extends State<MessageContextMenu> {
  // 外部 tap 判定:记录按下位置/时间,up 时若位移小且时长短→判定为点击→dismiss。
  Offset? _downPos;
  DateTime? _downTime;
  // tap 阈值:位移 < 18px 且时长 < 350ms 视为点击(而非拖拽滚动)。
  static const double _tapSlop = 18;
  static const Duration _tapTimeout = Duration(milliseconds: 350);

  bool _isTap(Offset upPos) {
    final p = _downPos;
    final t = _downTime;
    if (p == null || t == null) return false;
    if ((upPos - p).distance > _tapSlop) return false;
    if (DateTime.now().difference(t) > _tapTimeout) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 外部空白遮罩:用 Listener(pointer 层)判定 tap 关闭。
        // 不用 GestureDetector(opaque)——它会吞掉拖拽手势,导致弹菜单后列表不能滑动。
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) {
              _downPos = e.position;
              _downTime = DateTime.now();
            },
            onPointerUp: (e) {
              if (_isTap(e.position)) widget.onDismiss();
              _downPos = null;
              _downTime = null;
            },
            onPointerCancel: (_) {
              _downPos = null;
              _downTime = null;
            },
            child: const SizedBox.expand(),
          ),
        ),
        // 菜单本体:绝对定位(left, top),锚钉在可见区边缘。
        Positioned(
          left: widget.left,
          top: widget.top,
          child: _MenuBody(
            pointDown: widget.pointDown,
            tailOffsetX: widget.tailOffsetX,
            canRecall: widget.canRecall,
            onCopy: widget.onCopy,
            onDelete: widget.onDelete,
            onRecall: widget.onRecall,
            onSelect: widget.onSelect,
          ),
        ),
      ],
    );
  }
}

/// 菜单容器本体(深色背景 + 圆角 + 阴影 + 指向消息的三角)。
class _MenuBody extends StatelessWidget {
  /// 三角朝向:true=朝下(菜单在消息上方),false=朝上。
  final bool pointDown;
  /// 三角在菜单内的水平位置(指向消息中心)。
  final double tailOffsetX;
  /// 是否显示「撤回」按钮。
  final bool canRecall;
  final VoidCallback onCopy;
  final VoidCallback onDelete;
  final VoidCallback onRecall;
  final VoidCallback onSelect;

  const _MenuBody({
    required this.pointDown,
    required this.tailOffsetX,
    required this.canRecall,
    required this.onCopy,
    required this.onDelete,
    required this.onRecall,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // 三角画在"靠消息那一侧"的边、水平位置=tailOffsetX(指向消息中心)。
    // pointDown=true→底边外溢朝下(菜单在消息上方);false→顶边外溢朝上。
    final tail = Positioned(
      left: tailOffsetX - kMenuTailHalfWidth,
      top: pointDown ? null : -6,
      bottom: pointDown ? -6 : null,
      child: CustomPaint(
        size: const Size(10, 6),
        painter:
            _MenuTailPainter(color: AppMenuStyle.darkBg, pointDown: pointDown),
      ),
    );

    return Material(
      color: Colors.transparent,
      child: Stack(
        clipBehavior: Clip.none, // 让三角溢出到容器外指向消息
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            decoration: BoxDecoration(
              color: AppMenuStyle.darkBg,
              borderRadius:
                  BorderRadius.circular(AppMenuStyle.radiusAnchor),
              boxShadow: const [AppMenuStyle.shadow],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _MenuItem(
                    icon: Icons.content_copy,
                    label: '复制',
                    color: AppMenuStyle.darkFg,
                    onTap: onCopy),
                _MenuItem(
                    icon: Icons.delete_outline,
                    label: '删除',
                    color: AppMenuStyle.darkDanger,
                    onTap: onDelete),
                // 撤回按钮仅 canRecall=true 时显示(自己发的 + 5min 内)。
                // 与「删除」并列:删除=对自己隐藏(per-participant),
                // 撤回=双向软删(deleted_at),语义独立。
                if (canRecall)
                  _MenuItem(
                      icon: Icons.undo,
                      label: '撤回',
                      color: AppMenuStyle.darkDanger,
                      onTap: onRecall),
                _MenuItem(
                    icon: Icons.check_circle_outline,
                    label: '多选',
                    color: AppMenuStyle.darkFg,
                    onTap: onSelect),
              ],
            ),
          ),
          tail,
        ],
      ),
    );
  }
}

/// 菜单指向消息的小三角。pointDown=true→顶点朝下(菜单在上方时用)。
class _MenuTailPainter extends CustomPainter {
  final Color color;
  final bool pointDown;

  const _MenuTailPainter({required this.color, required this.pointDown});

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
  bool shouldRepaint(_MenuTailPainter old) =>
      color != old.color || pointDown != old.pointDown;
}

/// 菜单项:icon 在上、文字在下,垂直排列。点击触发 onTap。
class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: color),
            ),
          ],
        ),
      ),
    );
  }
}
