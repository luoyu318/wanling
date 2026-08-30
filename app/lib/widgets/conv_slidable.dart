import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

/// 左滑操作按钮描述(纯数据,由 [ConvSlidable] 渲染为纯色按钮)。
class SlideActionSpec {
  final IconData icon;
  final String label;
  final Color color;
  final Future<void> Function() onTap;

  const SlideActionSpec({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });
}

/// 会话列表项左滑操作容器(主流 IM 风格:按钮在 tile 背后,左滑露出)。
///
/// - 按钮布局:上 icon 下文字,垂直水平居中(白字 11sp,间距 4dp)
/// - 点击按钮:autoClose 自动收起该行,再触发 onTap
/// - 互斥收起:列表层需包 SlidableAutoCloseBehavior(同时只展开一行)
class ConvSlidable extends StatelessWidget {
  final Key slideKey;
  final List<SlideActionSpec> actions;
  final Widget child;

  const ConvSlidable({
    super.key,
    required this.slideKey,
    required this.actions,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Slidable(
      key: slideKey,
      endActionPane: ActionPane(
        motion: const BehindMotion(),
        // 3 按钮占行宽 60%,2 按钮占 40%;真机效果不佳时在此微调。
        extentRatio: actions.length >= 3 ? 0.6 : 0.4,
        children: [
          for (final a in actions)
            CustomSlidableAction(
              onPressed: (_) => unawaited(a.onTap()),
              autoClose: true,
              backgroundColor: a.color,
              foregroundColor: Colors.white,
              // 默认内边距过大导致「删除会话」四字被截断,收窄保证完整显示
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(a.icon),
                  const SizedBox(height: 4),
                  Text(
                    a.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white),
                  ),
                ],
              ),
            ),
        ],
      ),
      child: child,
    );
  }
}
