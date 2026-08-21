// desktop/lib/shell/app_canvas.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/conv_list_width_provider.dart';
import '../theme/desktop_theme.dart';
import 'nav_rail.dart';
import 'resize_handle.dart';
import 'window_resize_edges.dart';
// WindowActions 类型经 title_bar.dart re-export,不再单独 import
import 'title_bar.dart';

/// 窗口操作注入点:main 初始化 window_manager 成功后 override 为
/// WindowManagerActions;失败保持 null(系统标题栏 fallback 由 GTK 层
/// 保留,标题栏按钮隐藏)。
final windowActionsProvider = Provider<WindowActions?>((ref) => null);

/// 浮动卡片画布:外层 Row[透明工具条(通顶) | 主体区] + 主体区
/// Column[TitleBar | Row[会话卡片 | ResizeHandle | 聊天卡片]]。窗口右/底
/// 8px 边距提到最外层。两张卡片内容(已包 CardContainer)由调用方注入,
/// 会话卡片宽度由 convListWidthProvider 驱动(ResizeHandle 拖拽)。
class AppCanvas extends ConsumerWidget {
  final Widget conversationCard; // 会话列表卡片
  final Widget chatCard; // 聊天区卡片
  final WindowActions? actions;

  const AppCanvas({
    super.key,
    required this.conversationCard,
    required this.chatCard,
    this.actions,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brightness = Theme.of(context).brightness;
    final actions = this.actions ?? ref.watch(windowActionsProvider);
    final convWidth = ref.watch(convListWidthProvider);

    // WindowResizeEdges:无边框窗口的边缘缩放热区(frameless 后系统缩放
    // 边已去,Flutter 自绘),覆盖在最外层。
    return WindowResizeEdges(
      child: Scaffold(
        backgroundColor: DesktopTheme.canvasColor(brightness),
        body: Padding(
          padding: const EdgeInsets.only(right: 8, bottom: 8),
          child: Row(
            children: [
              const NavRail(),
              Expanded(
                child: Column(
                  children: [
                    TitleBar(actions: actions),
                    Expanded(
                      child: Row(
                        children: [
                          SizedBox(width: convWidth, child: conversationCard),
                          const ResizeHandle(),
                          Expanded(child: chatCard),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
