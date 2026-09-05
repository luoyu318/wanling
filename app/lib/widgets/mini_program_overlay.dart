// 小程序嵌入模式弹层宿主(C1 修复)。
// 机制:MiniProgramHost 挂在 MaterialApp.builder,Navigator 是 Host Stack 的
// child;嵌入页面(实例视图)与 Navigator 是兄弟分支,其 context 向上找不到
// NavigatorState → showDialog/showModalBottomSheet 的 Navigator.of 在 debug
// 抛 FlutterError / release 空解引用。本模块在 Host Stack 顶端(实例视图之上)
// 挂专用全局 Overlay 作弹层宿主,嵌入模式的弹层统一经 showMiniProgramOverlay
// 插入;路由模式(页面在 Navigator 内)不受影响,仍走 showDialog 系 API。
// 模板说明:本模块是「全局 key + 模块级登记表」型基础设施,无资源生命周期,
// StreamController 骨架不适用(对齐 mini_program_launcher 的豁免先例)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/providers/mini_program_manager_provider.dart';

/// 弹层宿主 Overlay 的全局 key(Host 挂载,helper 取 OverlayState)。
final GlobalKey<OverlayState> miniProgramOverlayKey = GlobalKey<OverlayState>();

/// 插入弹层时的前台 appid 快照,Host 在 manager 通知时对比决定是否批量关闭。
String? _openedWithForegroundAppid;

/// 在册弹层句柄(dismiss 幂等,重复调用无害)。
class _ActiveEntry {
  _ActiveEntry(this.entry, this.dismiss);

  final OverlayEntry entry;
  final void Function() dismiss;
}

final List<_ActiveEntry> _activeEntries = [];

/// 嵌入模式弹层宿主:挂在 MiniProgramHost Stack 顶端(实例视图之上、
/// 浮球/多任务视图之下)。空时渲染零内容,不影响既有布局。
class MiniProgramOverlayHost extends StatelessWidget {
  const MiniProgramOverlayHost({super.key});

  @override
  Widget build(BuildContext context) =>
      Overlay(key: miniProgramOverlayKey, initialEntries: const []);
}

/// 往弹层宿主插入一个带 barrier 的弹层;返回的 Future 在弹层关闭时完成
/// (携带关闭结果)。[bottomSheet]=true 时内容贴底(会话选择器/更多抽屉),
/// 否则居中(AlertDialog 自带 Material,直接居中放置)。
///
/// [sheetBackgroundColor]/[sheetTopRadius]:贴底形态的视觉壳(底色 + 顶部
/// 圆角),对齐 showModalBottomSheet 在路由模式提供的观感——嵌入分支的
/// Material(transparency) 只提供墨水反馈,不带底色,缺壳会透出被压暗的页面。
///
/// [context] 须为嵌入页面(ProviderScope 内)的 context:用于读取 manager
/// 前台快照,供前台变化时批量关闭(见 dismissMiniProgramOverlaysOnForegroundChange)。
Future<T?> showMiniProgramOverlay<T>({
  required BuildContext context,
  required Widget Function(
    BuildContext overlayCtx,
    void Function([T? result]) close,
  )
  builder,
  bool bottomSheet = false,
  Color sheetBackgroundColor = const Color(0xFFF7F7F7),
  double sheetTopRadius = 12,
  bool barrierDismissible = true,
}) {
  final overlayState = miniProgramOverlayKey.currentState;
  // fail fast:宿主未挂载说明 Host 层缺失,静默吞掉会让 JS 侧永久等不到
  // 弹窗结果(bridge 的 Future 悬挂),宁可显式崩
  if (overlayState == null) {
    throw StateError('MiniProgramOverlayHost 未挂载,嵌入模式弹层不可用');
  }
  _openedWithForegroundAppid = ProviderScope.containerOf(
    context,
  ).read(miniProgramManagerProvider).foregroundAppid;

  final completer = Completer<T?>();
  OverlayEntry? entry;
  void close([T? result]) {
    final e = entry;
    if (e == null) return;
    entry = null;
    _activeEntries.removeWhere((active) => active.entry == e);
    if (e.mounted) e.remove();
    if (!completer.isCompleted) completer.complete(result);
  }

  entry = OverlayEntry(
    builder: (overlayCtx) => _OverlayFade(
      child: Stack(
        children: [
          // barrier:点按关闭(dialog 语义=拒绝,sheet 语义=取消)
          Positioned.fill(
            child: GestureDetector(
              onTap: barrierDismissible ? () => close() : null,
              child: const ColoredBox(color: Colors.black54),
            ),
          ),
          if (bottomSheet)
            Align(
              alignment: Alignment.bottomLeft,
              child: Material(
                type: MaterialType.transparency,
                // 视觉壳:底色 + 顶部圆角(ClipRRect 防内容溢出圆角外)
                child: ClipRRect(
                  borderRadius: BorderRadius.vertical(
                      top: Radius.circular(sheetTopRadius)),
                  child: ColoredBox(
                    color: sheetBackgroundColor,
                    child: builder(overlayCtx, close),
                  ),
                ),
              ),
            )
          else
            Center(child: builder(overlayCtx, close)),
        ],
      ),
    ),
  );
  _activeEntries.add(_ActiveEntry(entry!, () => close()));
  overlayState.insert(entry!);
  return completer.future;
}

/// 关闭全部嵌入弹层(Host 层兜底入口)。
void dismissMiniProgramOverlays() {
  for (final active in List<_ActiveEntry>.of(_activeEntries)) {
    active.dismiss();
  }
}

/// 前台实例变化时关闭全部嵌入弹层:弹层 barrier 盖住一切入口,若悬浮到
/// 非小程序页面(最小化/切换实例/登出清空)会拦死宿主导航。前台未变
/// (同实例元信息刷新等通知)不动弹层。
void dismissMiniProgramOverlaysOnForegroundChange(String? foregroundAppid) {
  if (_activeEntries.isEmpty) return;
  if (foregroundAppid != null &&
      foregroundAppid == _openedWithForegroundAppid) {
    return;
  }
  dismissMiniProgramOverlays();
}

/// 弹层淡入:路由弹层有转场动画,overlay 插入是瞬时上屏,150ms 淡入对齐手感。
class _OverlayFade extends StatefulWidget {
  const _OverlayFade({required this.child});

  final Widget child;

  @override
  State<_OverlayFade> createState() => _OverlayFadeState();
}

class _OverlayFadeState extends State<_OverlayFade> {
  double _opacity = 0;

  @override
  void initState() {
    super.initState();
    // 下一帧再置 1 才能触发 implicit 动画(同帧置 1 无过渡)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _opacity = 1);
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: _opacity,
    duration: const Duration(milliseconds: 150),
    child: widget.child,
  );
}
