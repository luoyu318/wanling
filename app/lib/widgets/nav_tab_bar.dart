import 'package:flutter/material.dart';
import 'package:wanling_core/theme/app_colors.dart';

import 'avatar.dart';

/// agent 槽位数据(与 Agent 模型解耦,widget 测试无需构造完整模型)。
class NavAgentTab {
  final String id;
  final String name;

  /// agent 头像地址;为空时回退哈希色首字母头像(与 Avatar 组件同源)。
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

/// 会话槽位数据(与 Conversation 模型解耦,widget 测试无需构造完整模型)。
/// 无在线态(会话没有在线概念),仅名字/头像/未读。
class NavConvTab {
  final String id;
  final String name;
  final String? avatarUrl;
  final int unread;

  const NavConvTab({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.unread = 0,
  });
}

/// 底栏槽位描述:由 HomePage 从有效导航序列派生,组件保持纯展示(无拖拽)。
sealed class NavSlot {
  const NavSlot({required this.tabId});

  /// 槽位对应 tab:msg/wanling/agentId
  final String tabId;
}

/// 图标形态槽(消息/万灵)。
class NavIconSlot extends NavSlot {
  const NavIconSlot({
    required super.tabId,
    required this.label,
    required this.icon,
    required this.activeIcon,
    this.badge = 0,
  });

  final String label;
  final IconData icon;
  final IconData activeIcon;
  final int badge;
}

/// agent 头像槽。
class NavAgentSlot extends NavSlot {
  const NavAgentSlot({required super.tabId, required this.tab});

  final NavAgentTab tab;
}

/// 会话头像槽(好友/群/普通 agent 单聊/单 session):点按由上层路由跳聊天页。
class NavConvSlot extends NavSlot {
  const NavConvSlot({required super.tabId, required this.tab});

  final NavConvTab tab;
}

/// 自绘底部导航:槽位由上层按导航序列派生(任意排序),组件纯展示。
///
/// - 点按 onSlotTap(槽位号);长按 onSlotLongPress(进编辑页);更多槽点按 onMoreTap
/// - 视觉沿用现网规范(#F7F7F7 底、accent 绿选中、UnreadBadge 角标结构)
class NavTabBar extends StatelessWidget {
  const NavTabBar({
    super.key,
    required this.slots,
    required this.currentIndex,
    this.moreTab,
    required this.showMore,
    required this.onSlotTap,
    required this.onMoreTap,
    required this.onSlotLongPress,
  })  : assert(slots.length <= (showMore ? 4 : 5), '可见槽(消息/万灵/agent)最多 4/5 个');

  /// 可见槽位内容(序列前缀,固定项/agent 混合,顺序即渲染顺序)
  final List<NavSlot> slots;
  final int currentIndex;

  /// 更多槽当前激活的溢出 agent(null = 未激活,显示格子图标)
  final NavAgentTab? moreTab;
  final bool showMore;
  final ValueChanged<int> onSlotTap;
  final VoidCallback onMoreTap;
  final ValueChanged<int> onSlotLongPress;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        color: const Color(0xFFF7F7F7),
        height: 56,
        child: Row(
          children: [
            for (var i = 0; i < slots.length; i++)
              switch (slots[i]) {
                NavIconSlot s => _IconSlot(
                    slot: i,
                    data: s,
                    selected: currentIndex == i,
                    onTap: onSlotTap,
                    onLongPress: onSlotLongPress,
                  ),
                NavAgentSlot s => _AgentSlot(
                    slot: i,
                    tab: s.tab,
                    selected: currentIndex == i,
                    onTap: onSlotTap,
                    onLongPress: onSlotLongPress,
                  ),
                NavConvSlot s => _ConvSlot(
                    slot: i,
                    tab: s.tab,
                    selected: currentIndex == i,
                    onTap: onSlotTap,
                    onLongPress: onSlotLongPress,
                  ),
              },
            if (showMore)
              _MoreSlot(
                tab: moreTab,
                selected: currentIndex == slots.length,
                onTap: onMoreTap,
              ),
          ],
        ),
      ),
    );
  }
}

/// 图标形态槽(消息/万灵):点按切换,长按进编辑页。
class _IconSlot extends StatelessWidget {
  final int slot;
  final NavIconSlot data;
  final bool selected;
  final ValueChanged<int> onTap;
  final ValueChanged<int> onLongPress;

  const _IconSlot({
    required this.slot,
    required this.data,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accentGreen : AppColors.textSecondary;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(slot),
        onLongPress: () => onLongPress(slot),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _Badge(
                count: data.badge,
                child: Icon(
                    selected ? data.activeIcon : data.icon,
                    size: 24,
                    color: color)),
            const SizedBox(height: 2),
            Text(data.label,
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

/// agent 头像槽:点按切换,长按进编辑页(排序/编辑收编编辑页,底栏不再原地拖拽)。
class _AgentSlot extends StatelessWidget {
  final int slot;
  final NavAgentTab tab;
  final bool selected;
  final ValueChanged<int> onTap;
  final ValueChanged<int> onLongPress;

  const _AgentSlot({
    required this.slot,
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accentGreen : AppColors.textSecondary;
    final label = tab.name.characters.length > 5
        ? '${tab.name.characters.take(5).join()}…'
        : tab.name;
    return Expanded(
      // 热区撑满整个槽位,避免点击头像/文字以外区域无响应
      child: InkWell(
        onTap: () => onTap(slot),
        onLongPress: () => onLongPress(slot),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _AgentAvatar(
              name: tab.name,
              avatarUrl: tab.avatarUrl,
              online: tab.online,
              unread: tab.unread,
              size: 24,
            ),
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

/// 会话头像槽:点按由上层路由跳聊天页,长按进编辑页。无在线态。
class _ConvSlot extends StatelessWidget {
  final int slot;
  final NavConvTab tab;
  final bool selected;
  final ValueChanged<int> onTap;
  final ValueChanged<int> onLongPress;

  const _ConvSlot({
    required this.slot,
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.accentGreen : AppColors.textSecondary;
    final label = tab.name.characters.length > 5
        ? '${tab.name.characters.take(5).join()}…'
        : tab.name;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(slot),
        onLongPress: () => onLongPress(slot),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _AgentAvatar(
                name: tab.name, avatarUrl: tab.avatarUrl, unread: tab.unread, size: 24),
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
                ? _AgentAvatar(
                    name: active.name,
                    avatarUrl: active.avatarUrl,
                    online: active.online,
                    unread: active.unread,
                    size: 24)
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

/// agent 头像:大圆角方形(有头像用图片,否则哈希色首字母) + 在线小绿点 + 未读角标。
/// 选中态不用外圈,由槽位文字颜色/字重表达(对齐消息/万灵槽的选中语言)。
class _AgentAvatar extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final bool online;
  final int unread;
  final double size;

  const _AgentAvatar({
    required this.name,
    this.avatarUrl,
    this.online = false,
    this.unread = 0,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final inner = Stack(
      clipBehavior: Clip.none,
      children: [
        // 有头像走 Avatar(网络图,真实 app 在 ProviderScope 内);
        // 无头像走哈希色首字母(纯本地渲染,widget 测试无需 riverpod)
        if (avatarUrl != null)
          Avatar(
            name: name,
            url: avatarUrl,
            size: size,
            radius: size * 0.28,
          )
        else
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Avatar.colorFor(name),
              borderRadius: BorderRadius.circular(size * 0.28),
            ),
            alignment: Alignment.center,
            child: Text(
              name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: TextStyle(
                  fontSize: size * 0.5,
                  color: Colors.white,
                  fontWeight: FontWeight.w600),
            ),
          ),
        if (online)
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
    return _Badge(count: unread, child: inner);
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
