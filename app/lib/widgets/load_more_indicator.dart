import 'package:flutter/material.dart';

/// 顶部加载指示器（飞书风格）。
/// 只在加载中显示细进度条，不加载时只占 4px 高度。
/// hasMore=false 时 ListView 不渲染此 item（itemCount 不 +1），故无需在内部判断 hasMore。
class LoadMoreIndicator extends StatelessWidget {
  final bool isLoading;

  const LoadMoreIndicator({super.key, required this.isLoading});

  @override
  Widget build(BuildContext context) {
    if (!isLoading) {
      return const SizedBox(height: 4);
    }

    return SizedBox(
      height: 24,
      child: Center(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(1),
          child: SizedBox(
            width: 80,
            height: 2,
            child: LinearProgressIndicator(
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation(
                Theme.of(context).primaryColor.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
