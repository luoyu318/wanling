import 'package:flutter/material.dart';

/// 会话列表项(纯展示组件):头像占位方块 + 名称 + 摘要 + 未读角标。
/// 所有数据由构造参数显式传入,选中态由 [selected] 控制。
class ConversationListItem extends StatelessWidget {
  final String convId;
  final String name;
  final String subtitle;
  final String time;
  final int unreadCount;
  final bool selected;
  final VoidCallback? onTap;

  const ConversationListItem({
    super.key,
    required this.convId,
    required this.name,
    required this.subtitle,
    required this.time,
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
              // 头像占位方块:名称首字符,无网络图片依赖(Task 后续接头像再换)。
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  name.isEmpty ? '#' : name.characters.first,
                  style: TextStyle(
                    fontSize: 15,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
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
              // 右列:上时间(常显),下未读角标(无未读时占位保持行高稳定)。
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurface.withValues(alpha: 0.4),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (unreadCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.error,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$unreadCount',
                        style: TextStyle(fontSize: 11, color: scheme.onError),
                      ),
                    )
                  else
                    const SizedBox(height: 17),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
