// desktop/lib/shell/resize_handle.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/conv_list_width_provider.dart';
import '../theme/desktop_theme.dart';

/// 卡片间透明分割线:8px 宽,悬停 ⇔ 光标 + 显把手短条,水平拖拽调
/// convListWidthProvider(拖拽中即时更新,松手 clamp+持久化由 provider 承担)。
class ResizeHandle extends ConsumerStatefulWidget {
  const ResizeHandle({super.key});

  @override
  ConsumerState<ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends ConsumerState<ResizeHandle> {
  late final ValueNotifier<bool> _hovering;

  @override
  void initState() {
    super.initState();
    _hovering = ValueNotifier<bool>(false);
  }

  @override
  void dispose() {
    _hovering.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => _hovering.value = true,
      onExit: (_) => _hovering.value = false,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) {
          final cur = ref.read(convListWidthProvider);
          ref.read(convListWidthProvider.notifier).setWidth(cur + d.delta.dx);
        },
        child: SizedBox(
          width: 8,
          child: Center(
            child: ValueListenableBuilder<bool>(
              valueListenable: _hovering,
              builder: (_, h, __) => AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 3,
                height: h ? 64 : 56,
                decoration: BoxDecoration(
                  color: DesktopTheme.cardBorderColor(
                    Theme.of(context).brightness,
                  ).withValues(alpha: h ? 0.9 : 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
