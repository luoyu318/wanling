// desktop/lib/shell/title_bar.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wanling_core/providers/auth_provider.dart';

import '../widgets/avatar.dart';
import 'window_actions.dart';

// TitleBar 构造参数暴露 WindowActions 类型,导出以便消费方无需单独 import。
export 'window_actions.dart';

/// 透明标题栏(画布色上):左用户头像(authProvider.user),中拖拽区
/// (双击最大化/还原),右 ⚙ 设置 + ─ □ ✕。✕ 悬停红(#E81123)。
/// actions 注入窗口操作(生产 WindowManagerActions / 测试 fake),缺省
/// null 时按钮隐藏(如 window_manager 初始化失败的降级场景仍可拖拽)。
class TitleBar extends ConsumerStatefulWidget {
  final WindowActions? actions;

  const TitleBar({super.key, this.actions});

  @override
  ConsumerState<TitleBar> createState() => _TitleBarState();
}

class _TitleBarState extends ConsumerState<TitleBar> {
  bool _maximized = false;
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _syncMaximized();
    _sub = widget.actions?.onStateChanged.listen((_) => _syncMaximized());
  }

  // isMaximized 为异步:拉取最新值,变化才 setState。
  Future<void> _syncMaximized() async {
    final v = (await widget.actions?.isMaximized) ?? false;
    if (!mounted || v == _maximized) return;
    setState(() => _maximized = v);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider.select((s) => s.user));
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          // 21px 与工具条 icon 同视觉尺寸;Center 撑满 40px 高确保垂直居中。
          Center(
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Avatar(
                key: const ValueKey('titlebar_logo'),
                name: user?.displayName ?? '',
                url: user?.avatarUrl,
                size: 21,
                radius: 10.5,
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: widget.actions?.toggleMaximize,
              onPanStart: (_) => widget.actions?.dragWindow(),
              child: const SizedBox.expand(),
            ),
          ),
          if (widget.actions != null) ...[
            _btn(
              key: 'titlebar_settings',
              icon: Icons.settings_outlined,
              tip: '设置',
              onTap: () => context.go('/settings'),
            ),
            _btn(
              key: 'titlebar_minimize',
              icon: Icons.horizontal_rule,
              tip: '最小化',
              onTap: widget.actions!.minimize,
            ),
            _btn(
              key: 'titlebar_maximize',
              icon: _maximized ? Icons.filter_none : Icons.crop_square,
              tip: _maximized ? '还原' : '最大化',
              onTap: widget.actions!.toggleMaximize,
            ),
            _btn(
              key: 'titlebar_close',
              icon: Icons.close,
              tip: '关闭',
              onTap: widget.actions!.close,
              hoverColor: const Color(0xFFE81123),
              hoverIconColor: Colors.white,
            ),
          ],
        ],
      ),
    );
  }

  Widget _btn({
    required String key,
    required IconData icon,
    required String tip,
    required VoidCallback onTap,
    Color? hoverColor,
    Color? hoverIconColor,
  }) {
    return _HoverBtn(
      key: ValueKey(key),
      icon: icon,
      tip: tip,
      onTap: onTap,
      hoverColor: hoverColor,
      hoverIconColor: hoverIconColor,
    );
  }
}

/// 系统按钮:默认透明,悬停浅灰底;✕ 覆盖 hoverColor 红。
class _HoverBtn extends StatefulWidget {
  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final Color? hoverColor;
  final Color? hoverIconColor;

  const _HoverBtn({
    super.key,
    required this.icon,
    required this.tip,
    required this.onTap,
    this.hoverColor,
    this.hoverIconColor,
  });

  @override
  State<_HoverBtn> createState() => _HoverBtnState();
}

class _HoverBtnState extends State<_HoverBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.tip,
          child: Container(
            width: 42,
            height: 40,
            color: _hover
                ? widget.hoverColor ?? scheme.onSurface.withValues(alpha: 0.06)
                : Colors.transparent,
            child: Icon(
              widget.icon,
              size: 18,
              color: _hover && widget.hoverIconColor != null
                  ? widget.hoverIconColor
                  : scheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
        ),
      ),
    );
  }
}
