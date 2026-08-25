import 'package:flutter/material.dart';
import 'agent_type_badge.dart';
import 'avatar.dart';

/// 会话列表项(纯展示组件):头像([Avatar],真图+字母色块兜底+未读 badge) +
/// 名称(可选 agent type 描边小标签) + 摘要 + 时间。
/// 所有数据由构造参数显式传入,选中态由 [selected] 控制。
/// 选中态柔和主色 tint 底(与 NavRail 选中语言一致),文字保持 onSurface,
/// 区分靠底色 + 名称字重。
class ConversationListItem extends StatelessWidget {
  final String convId;
  final String name;
  final String subtitle;
  final String time;
  final String? avatarUrl;
  final int unreadCount;
  final bool selected;
  /// agent 类型标签:非 null 渲染徽标(空串=「智能体」),null=不渲染
  /// (好友/群等非 agent 会话)。仅 dm_user_agent 会话传值。
  final String? agentType;
  /// 多 session agent 的 session 数(一级列表行摘要下方第二行,
  /// 对齐 app messages_page「N 个会话/待处理」);<0 不渲染。
  final int sessionCount;
  /// 多 session agent 的待处理交互卡数(>0 时第二行红字显示)。
  final int pendingCount;
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
    this.agentType,
    this.sessionCount = -1,
    this.pendingCount = 0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey('conv_$convId'),
      // 选中态柔和主色 tint 底,文字不反白(次级文字仍降透明度)。
      color: selected ? scheme.primary.withValues(alpha: 0.10) : null,
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
                              color: scheme.onSurface,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        // agent type 实心小胶囊:样式对齐 app AgentBadge
                        // (文案/配色来自 server 注册表)。仅 agent 会话渲染
                        // (agentType 非 null);空 type 显示「智能体」。
                        if (agentType != null) ...[
                          const SizedBox(width: 5),
                          AgentTypeBadge(type: agentType!),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    // 摘要行:多 session agent 传空串(无消息流,摘要无意义),
                    // 空串不渲染避免留白,第二行由 sessionCount 接管。
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    // 多 session agent 第二行:待处理红字优先,否则会话数
                    // (对齐 app messages_page 口径)。
                    if (sessionCount >= 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        pendingCount > 0
                            ? '待处理 $pendingCount 项'
                            : (sessionCount > 0 ? '$sessionCount 个会话' : '暂无会话'),
                        style: TextStyle(
                          fontSize: 11,
                          color: pendingCount > 0
                              ? scheme.error
                              : scheme.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                    ],
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
