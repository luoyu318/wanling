import 'package:flutter/material.dart';
import 'package:marquee/marquee.dart';
import '../utils/directory_utils.dart';

class DirectoryTile extends StatelessWidget {
  final DirectoryInfo info;
  final bool isSelected;
  final VoidCallback onTap;

  const DirectoryTile({
    super.key,
    required this.info,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isUncategorized = info.path == null;
    final displayPath = info.path ?? '未归类';
    final opacity = isUncategorized ? 0.6 : 1.0;
    final pathColor =
        isSelected ? const Color(0xFF007AFF) : const Color(0xFF333333);
    final pathWeight = isSelected ? FontWeight.w500 : FontWeight.w400;
    final pathStyle = TextStyle(
      fontSize: 13,
      fontWeight: pathWeight,
      color: pathColor,
    );

    return Opacity(
      opacity: opacity,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFFE8F0FE) : Colors.transparent,
            border: isSelected
                ? const Border(
                    right: BorderSide(color: Color(0xFF007AFF), width: 3),
                  )
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: directoryColor(info.path),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: Text(
                    directoryInitial(info.path),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF333333),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isSelected)
                      SizedBox(
                        height: 18,
                        child: Marquee(
                          text: displayPath,
                          style: pathStyle,
                          scrollAxis: Axis.horizontal,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          blankSpace: 40.0,
                          velocity: 30.0,
                          startPadding: 0,
                          pauseAfterRound: const Duration(seconds: 1),
                          showFadingOnlyWhenScrolling: true,
                          fadingEdgeStartFraction: 0.0,
                          fadingEdgeEndFraction: 0.0,
                        ),
                      )
                    else
                      Text(
                        displayPath,
                        overflow: TextOverflow.ellipsis,
                        style: pathStyle,
                      ),
                    const SizedBox(height: 2),
                    Builder(builder: (_) {
                      if (info.pendingCount > 0) {
                        return Text(
                          '${info.sessionCount} 个会话 · 待处理 ${info.pendingCount} 项',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFFE53935),
                          ),
                        );
                      }
                      if (info.busyCount > 0) {
                        return Text(
                          '${info.sessionCount} 个会话 · 活跃 ${info.busyCount}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF07C160),
                          ),
                        );
                      }
                      return Text(
                        '${info.sessionCount} 个会话',
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF888888),
                        ),
                      );
                    }),
                  ],
                ),
              ),
              if (info.unreadCount > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3B30),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${info.unreadCount}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
