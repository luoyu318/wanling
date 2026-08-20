import 'package:flutter/material.dart';

import 'avatar.dart';

/// 会话列表项(纯展示组件):头像([Avatar],真图+字母色块兜底+未读 badge) +
/// 名称 + 摘要 + 时间。
/// 所有数据由构造参数显式传入,选中态由 [selected] 控制。
class ConversationListItem extends StatelessWidget {
  final String convId;
  final String name;
  final String subtitle;
  final String time;
  final String? avatarUrl;
  final int unreadCount;
  final bool selected;
  final VoidCallback? onTap;

  const ConversationListItem({
    super.key,
    required this.convId,
    required this.name,
    required this.subtitle,
    required this.time,
    this.avatarUrl,
    this.unreadCount = 0,
    this.selected = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('conv_$convId'),
      color: selected ? scheme.secondaryContainer : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              // 头像:真图优先,字母色块兜底,未读红圆 badge 在右上角(对齐 app)。
              Avatar(
                name: name,
                url: avatarUrl,
                size: 36,
                radius: 8,
                unreadCount: unreadCount,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: scheme.onSurface,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 右列:时间(未读 badge 已挪到头像右上角)。
              Text(
                time,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
