import 'package:flutter/material.dart';
import 'package:wanling_core/theme/app_colors.dart';

/// agent 槽位数据(与 Agent 模型解耦,widget 测试无需构造完整模型)。
class NavAgentTab {
  final String id;
  final String name;
  final String? avatarUrl;
  final bool online;
  final int unread;

  const NavAgentTab({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.online = false,
    this.unread = 0,
  });
}

/// 自绘底部导航:消息/万灵固定槽 + agent 头像槽(长按拖拽排序) + 可选更多槽。
///
/// 槽位编号:0=消息 1=万灵 2..=agent;showMore=true 时最后一槽=更多(编号 4)。
/// 视觉沿用现网规范(#F7F7F7 底、accent 绿选中、UnreadBadge 角标结构)。
/// 替换 BottomNavigationBar 的原因:需要头像形态 item + 长按拖拽 + 更多槽激活态。
class NavTabBar extends StatelessWidget {
  const NavTabBar({
    super.key,
    required this.currentIndex,
    required this.totalUnread,
    required this.agentTabs,
    required this.showMore,
    this.moreTab,
    required this.onSlotTap,
    required this.onMoreTap,
    required this.onAgentReorder,
  });

  final int currentIndex;
  final int totalUnread;

  /// 可见 agent 槽位内容(调用方保证 ≤3;showMore 时 ≤2)
  final List<NavAgentTab> agentTabs;
  final bool showMore;

  /// 更多槽当前激活的溢出 agent(null = 未激活,显示格子图标)
  final NavAgentTab? moreTab;
  final ValueChanged<int> onSlotTap;
  final VoidCallback onMoreTap;

  /// agent 槽间拖拽排序:draggedId 落到 agentTabs[targetIndex] 槽位
  final void Function(String agentId, int targetIndex) onAgentReorder;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        color: const Color(0xFFF7F7F7),
        height: 56,
        child: Row(
          children: [
            _FixedSlot(
              index: 0,
              label: '消息',
              selected: currentIndex == 0,
              onTap: onSlotTap,
              icon: Icons.chat_bubble_outline,
              activeIcon: Icons.chat_bubble,
              badge: totalUnread,
            ),
            _FixedSlot(
              index: 1,
              label: '万灵',
              selected: currentIndex == 1,
              onTap: onSlotTap,
              icon: Icons.auto_awesome_outlined,
              activeIcon: Icons.auto_awesome,
            ),
            for (var i = 0; i < agentTabs.length; i++)
              _AgentSlot(
                index: i,
                slotNumber: 2 + i,
                tab: agentTabs[i],
                selected: currentIndex == 2 + i,
                onTap: onSlotTap,
                onAccepted: onAgentReorder,
              ),
            if (showMore)
              _MoreSlot(
                tab: moreTab,
                selected: currentIndex == 4,
                onTap: onMoreTap,
              ),
          ],
        ),
      ),
    );
  }
}

/// 图标形态固定槽(消息/万灵)。
class _FixedSlot extends StatelessWidget {
  final int index;
  final String label;
  final bool selected;
  final ValueChanged<int> onTap;
  final IconData icon;
  final IconData activeIcon;
  final int badge;

  const _FixedSlot({
    required this.index,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.icon,
    required this.activeIcon,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accentGreen : AppColors.textSecondary;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Badge(
                count: badge,
                child: Icon(selected ? activeIcon : icon, size: 24, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    color: color,
                    fontWeight: selected ? FontWeight.w600 : null)),
          ],
        ),
      ),
    );
  }
}

/// agent 头像槽:长按拖出 + 接收别的 agent 落入(排序)。
class _AgentSlot extends StatelessWidget {
  final int index; // agentTabs 内下标(排序目标)
  final int slotNumber; // 底栏槽位编号(2+i)
  final NavAgentTab tab;
  final bool selected;
  final ValueChanged<int> onTap;
  final void Function(String, int) onAccepted;

  const _AgentSlot({
    required this.index,
    required this.slotNumber,
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onAccepted,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = _AgentAvatar(tab: tab, size: 24, ring: selected);
    return Expanded(
      child: DragTarget<NavAgentTab>(
        onWillAcceptWithDetails: (d) => d.data.id != tab.id,
        onAcceptWithDetails: (d) => onAccepted(d.data.id, index),
        builder: (context, candidate, _) {
          final hovering = candidate.isNotEmpty;
          return LongPressDraggable<NavAgentTab>(
            data: tab,
            delay: const Duration(milliseconds: 120),
            feedback: _AgentAvatar(tab: tab, size: 32, ring: false),
            childWhenDragging: Opacity(opacity: 0.4, child: avatar),
            child: InkWell(
              onTap: () => onTap(slotNumber),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // 悬停目标高亮:细绿框由 _AgentAvatar ring 呈现,此处叠加边框语义即可
                  hovering
                      ? Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                                color: AppColors.accentGreen, width: 1.5),
                          ),
                          child: avatar,
                        )
                      : avatar,
                  const SizedBox(height: 2),
                  _slotLabel(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _slotLabel() {
    final color = selected ? AppColors.accentGreen : AppColors.textSecondary;
    final name = tab.name;
    final label = name.characters.length > 5
        ? '${name.characters.take(5).join()}…'
        : name;
    return Text(label,
        style: TextStyle(
            fontSize: 10,
            color: color,
            fontWeight: selected ? FontWeight.w600 : null));
  }
}

/// 更多槽:未激活显示格子图标,激活显示溢出 agent 头像+名字。
class _MoreSlot extends StatelessWidget {
  final NavAgentTab? tab;
  final bool selected;
  final VoidCallback onTap;

  const _MoreSlot({required this.tab, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accentGreen : AppColors.textSecondary;
    final active = tab;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            active != null
                ? _AgentAvatar(tab: active, size: 24, ring: true)
                : Icon(Icons.apps, size: 24, color: color),
            const SizedBox(height: 2),
            Text(
              active != null ? _truncate(active.name) : '更多',
              style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: selected ? FontWeight.w600 : null),
            ),
          ],
        ),
      ),
    );
  }

  static String _truncate(String name) => name.characters.length > 5
      ? '${name.characters.take(5).join()}…'
      : name;
}

/// agent 头像:圆形 + 在线小绿点 + 未读角标 + 选中环。
class _AgentAvatar extends StatelessWidget {
  final NavAgentTab tab;
  final double size;
  final bool ring;

  const _AgentAvatar({required this.tab, required this.size, required this.ring});

  @override
  Widget build(BuildContext context) {
    final inner = Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: AppColors.textSecondary.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Text(
            tab.name.isEmpty ? '?' : tab.name.characters.first.toUpperCase(),
            style: TextStyle(
                fontSize: size * 0.5,
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600),
          ),
        ),
        if (tab.online)
          Positioned(
            right: -1,
            bottom: -1,
            child: Container(
              width: size * 0.3,
              height: size * 0.3,
              decoration: BoxDecoration(
                color: AppColors.accentGreen,
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFF7F7F7), width: 1.5),
              ),
            ),
          ),
      ],
    );
    return _Badge(
      count: tab.unread,
      child: ring
          ? Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular((size + 4) / 2),
                border:
                    Border.all(color: AppColors.accentGreen, width: 1.5),
              ),
              child: inner,
            )
          : inner,
    );
  }
}

/// 未读角标(沿用现网 UnreadBadge 视觉:右上红圆)。
class _Badge extends StatelessWidget {
  final int count;
  final Widget child;
  const _Badge({required this.count, required this.child});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: -5,
          right: -7,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.danger,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: const Color(0xFFF7F7F7), width: 1.5),
            ),
            constraints: const BoxConstraints(minWidth: 15),
            child: Text(
              count > 99 ? '99+' : '$count',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 9, color: Colors.white, height: 1.2),
            ),
          ),
        ),
      ],
    );
  }
}
