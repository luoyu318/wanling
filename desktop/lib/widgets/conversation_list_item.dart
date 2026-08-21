import 'package:flutter/material.dart';

import 'avatar.dart';

/// 会话列表项(纯展示组件):头像([Avatar],真图+字母色块兜底+未读 badge) +
/// 名称(可选 agent type 描边小标签) + 摘要 + 时间。
/// 所有数据由构造参数显式传入,选中态由 [selected] 控制。
/// 选中态仿主流 IM:品牌绿底 + 白字(浅色主题原名黑字在浅容器上不显眼)。
class ConversationListItem extends StatelessWidget {
  final String convId;
  final String name;
  final String subtitle;
  final String time;
  final String? avatarUrl;
  final int unreadCount;
  final bool selected;
  /// agent 类型标签(如 opencode / hermes),空串不渲染。
  final String agentType;
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
    this.agentType = '',
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('conv_$convId'),
      // 选中态品牌绿底,配白字(次级文字白色降透明度)。
      color: selected ? scheme.primary : null,
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
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: selected
                                  ? Colors.white
                                  : scheme.onSurface,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        // agent type 描边小标签:品牌色文字 + 半透明描边,
                        // 选中态反白避免绿底上糊成一团。
                        if (agentType.isNotEmpty) ...[
                          const SizedBox(width: 5),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: selected
                                    ? Colors.white.withValues(alpha: 0.7)
                                    : scheme.primary.withValues(alpha: 0.5),
                              ),
                            ),
                            child: Text(
                              agentType,
                              style: TextStyle(
                                fontSize: 10,
                                height: 1.2,
                                color: selected
                                    ? Colors.white
                                    : scheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: selected
                            ? Colors.white.withValues(alpha: 0.75)
                            : scheme.onSurface.withValues(alpha: 0.55),
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
                  color: selected
                      ? Colors.white.withValues(alpha: 0.6)
                      : scheme.onSurface.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
