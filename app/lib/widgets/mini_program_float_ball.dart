// 小程序多任务浮球:吸附态贴边半透明(露 1/3),点击直达多任务视图;
// 长按拖拽,松手就近吸附。由 Host 放在根 Stack 顶层(需要 Stack 父级)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/services/mini_program_manager.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'avatar.dart';

/// 小程序多任务浮球。
class MiniProgramFloatBall extends ConsumerStatefulWidget {
  const MiniProgramFloatBall({
    super.key,
    required this.instances,
    required this.onTap,
  });

  /// 保活实例(最近一个用于渲染;多于 1 个时拖拽中显示数量角标)。
  final List<MiniProgramInstance> instances;

  /// 点击浮球 → Host 打开多任务视图。
  final VoidCallback onTap;

  @override
  ConsumerState<MiniProgramFloatBall> createState() =>
      _MiniProgramFloatBallState();
}

class _MiniProgramFloatBallState extends ConsumerState<MiniProgramFloatBall> {
  static const double _size = 56;
  static const double _reveal = _size / 3; // 吸附态露出宽度
  static const double _edgePad = 4; // 拖拽贴边留缝

  bool _left = false; // 当前吸附侧(初始右侧,与初始位置一致)
  late Offset _pos; // 球完整尺寸下的逻辑位置
  late Offset _dragStartPos; // 长按拖拽起始位置
  bool _placed = false;
  bool _dragging = false;

  double get _screenW => MediaQuery.of(context).size.width;
  double get _screenH => MediaQuery.of(context).size.height;

  /// y 钳制:避开状态栏,不拖出屏幕底。
  Offset _clampDy(Offset p) {
    final dy = p.dy.clamp(MediaQuery.of(context).padding.top + _edgePad,
        _screenH - _size - _edgePad);
    return Offset(p.dx, dy);
  }

  /// 松手就近吸附:球心在左半屏吸左,否则吸右。
  void _snapToNearestEdge() {
    final centerX = _pos.dx + _size / 2;
    _left = centerX < _screenW / 2;
    setState(() {
      _pos = Offset(_left ? _edgePad : _screenW - _size - _edgePad, _pos.dy);
      _dragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // fail fast:浮球没有实例就没有存在意义,Host 不应在空列表时挂载
    assert(widget.instances.isNotEmpty, '浮球至少需要一个保活实例');
    if (!_placed) {
      _placed = true;
      _pos = Offset(_screenW - _size - _edgePad, _screenH * 0.32);
    }
    final recent = widget.instances.first;
    final count = widget.instances.length;
    // 实例元数据回填(D):快照常为空,按 appid 查注册列表取最新 name/iconUrl
    final programs =
        ref.watch(miniProgramsProvider).valueOrNull ?? const [];
    final meta = resolveInstanceMeta(
      recent,
      programs,
      ref.watch(apiProvider).baseUrl,
    );
    final color = Avatar.colorFor(meta.name);

    final ball = Container(
      width: _size,
      height: _size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
              color: color.withValues(alpha: 0.45),
              blurRadius: 16,
              offset: const Offset(0, 6)),
        ],
      ),
      child: Stack(
        children: [
          Center(
            child: meta.iconUrl.isNotEmpty
                ? Avatar(
                    name: meta.name,
                    url: meta.iconUrl,
                    size: 40,
                    radius: 12,
                  )
                : Text(
                    _initial(meta.name),
                    style: const TextStyle(fontSize: 26, color: Colors.white),
                  ),
          ),
          // 多实例:拖拽中显示数量角标
          if (count > 1 && _dragging)
            Positioned(
              right: 2,
              top: 2,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                    color: Colors.red, shape: BoxShape.circle),
                child: Text('$count',
                    style: const TextStyle(
                        color: Colors.white, fontSize: 9, height: 1)),
              ),
            ),
        ],
      ),
    );

    // 吸附态:Positioned 只占露出宽度(1/3),OverflowBox 让球体溢出、
    // 由 Stack 裁剪出「藏 2/3 露 1/3」的视觉,且命中区域恰为可见部分;
    // 拖拽态完整显示。
    return Positioned(
      left: _dragging ? _pos.dx : (_left ? 0 : _screenW - _reveal),
      top: _pos.dy,
      width: _dragging ? _size : _reveal,
      height: _size,
      child: GestureDetector(
        // 点击 → 直接打开多任务视图
        onTap: widget.onTap,
        // 长按拖拽,松手就近吸附
        onLongPressStart: (d) {
          _dragStartPos = _pos;
          setState(() => _dragging = true);
        },
        onLongPressMoveUpdate: (d) {
          setState(() => _pos = _clampDy(_dragStartPos + d.offsetFromOrigin));
        },
        onLongPressEnd: (_) => _snapToNearestEdge(),
        // 手势被系统打断(弹窗等)时兜底复位,防 _dragging 卡 true 球停在半空
        onLongPressCancel: _snapToNearestEdge,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: _dragging ? 1.0 : 0.45,
          child: _dragging
              ? ball
              : OverflowBox(
                  // 左吸附露球右 1/3,右吸附露球左 1/3
                  alignment:
                      _left ? Alignment.centerRight : Alignment.centerLeft,
                  minWidth: 0,
                  maxWidth: _size,
                  minHeight: 0,
                  maxHeight: _size,
                  child: ball,
                ),
        ),
      ),
    );
  }

  /// 首字母(空名 fallback '?'),runes 取码点兼容中文/emoji。
  static String _initial(String name) {
    if (name.isEmpty) return '?';
    return String.fromCharCode(name.runes.first).toUpperCase();
  }
}
