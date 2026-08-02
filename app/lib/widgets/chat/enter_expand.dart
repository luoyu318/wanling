import 'package:flutter/material.dart';

/// 新消息入场淡入动画:首次 build 时视觉淡入,布局高度恒定。
///
/// 用于卡片 / reasoning(思考)消息实时首次出现时平滑显现,而非瞬间出现。
/// [animate] 控制是否播放:
/// - live sliver 实时新消息传 true → FadeTransition 淡入;
/// - 历史消息加载 / 流式终态替换(占位已淡入过)传 false → 直接显示完整内容,
///   避免下滑看历史时每条都播动画、或 reasoning 占位替换后重播闪烁。
///
/// 注意:不做真高度展开(SizeTransition)。卡片高度由内部 AnimatedSize 控制,
/// 入场淡入不影响布局高度 —— 否则 SliverList 懒加载重建时动画从 0 高度重播,
/// 内容瞬时不足会触发 ranOut → viewport correctBy 硬拉回 px,表现为卡片场景
/// 内容被整体顶动/下拉(与流式气泡逐行增高、高度恒为内容真实值的机制对齐)。
class EnterExpand extends StatefulWidget {
  final Widget child;

  /// 是否播放入场展开动画。false 时等价于直接显示 [child]。
  final bool animate;

  const EnterExpand({super.key, required this.child, required this.animate});

  @override
  State<EnterExpand> createState() => _EnterExpandState();
}

class _EnterExpandState extends State<EnterExpand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _factor;

  @override
  void initState() {
    super.initState();
    // 必须在 initState 创建(而非 late final 惰性初始化):
    // 惰性初始化若在 dispose 后才被访问(animate=false 时),createTicker 会
    // 在 element 已 deactivated 时查找 TickerMode ancestor 抛异常。
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: 0,
    );
    _factor = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    if (widget.animate) {
      _ctrl.forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.animate) return widget.child;
    // 视觉淡入,布局高度恒为 child 完整高度:不做 SizeTransition 真高度展开,
    // 避免 SliverList 懒加载重建时动画从 0 高度重播导致内容不足 ranOut。
    return FadeTransition(
      opacity: _factor,
      child: widget.child,
    );
  }
}
