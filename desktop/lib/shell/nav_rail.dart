import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wanling_core/providers/auth_provider.dart';

import '../providers/no_conversation_hint_provider.dart';
import '../providers/tab_reselect_provider.dart';
import '../widgets/account_switcher.dart';
import '../widgets/avatar.dart';

/// 搜索聚焦请求:工具条 🔍 置 true → ConversationList watch 后聚焦搜索框
/// 并回置 false(单向脉冲,不 watch 列表自身)。
final navRailSearchFocusProvider = StateProvider<bool>((ref) => false);

/// 左侧 52px 透明工具条(浮动卡片布局,通顶):顶 用户头像 + 🔍,中
/// 消息/万灵,底 AccountSwitcher(iconOnly,切换服务器/账号)。
/// 设置入口在标题栏。离开消息页清 noConversationHintProvider 逻辑保留。
class NavRail extends ConsumerWidget {
  const NavRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authProvider.select((s) => s.user));
    final location = GoRouterState.of(context).uri.path;
    final scheme = Theme.of(context).colorScheme;

    Widget navItem(IconData icon, String label, String route, String key) {
      final selected = location.startsWith(route);
      return Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 300),
        child: Material(
          color: Colors.transparent,
          child: InkResponse(
            key: ValueKey(key),
            onTap: () {
              if (route != '/messages') {
                ref.read(noConversationHintProvider.notifier).state = null;
              }
              if (selected) {
                // 重复点击当前 tab:go 无路由变化,发脉冲让壳层清二级
                // session 列表回一级(tabReselectProvider 消费后清零)。
                ref.read(tabReselectProvider.notifier).state = route;
                return;
              }
              context.go(route);
            },
            radius: 18,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                color: selected ? scheme.primary.withValues(alpha: 0.12) : null,
                border: Border.all(color: Colors.transparent),
              ),
              child: Stack(
                children: [
                  if (selected)
                    Positioned(
                      left: 0, top: 8, bottom: 8,
                      child: Container(width: 3, decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      )),
                    ),
                  Center(child: Icon(icon, size: 21,
                    color: selected ? scheme.primary : scheme.onSurface.withValues(alpha: 0.6))),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: 52,
      child: Column(
        children: [
          // 头像与窗口顶部的间距(与右/底 8px 画布边距同量级,视觉透气)。
          const SizedBox(height: 8),
          // 用户头像置顶(搜索上方):填满 36x36 容器,与 navItem 同尺寸。
          SizedBox(
            width: 36,
            height: 36,
            child: Center(
              child: Avatar(
                key: const ValueKey('navrail_user_avatar'),
                name: user?.displayName ?? '',
                url: user?.avatarUrl,
                size: 36,
                radius: 18,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Tooltip(
            message: '搜索',
            waitDuration: const Duration(milliseconds: 300),
            child: IconButton(
              key: const ValueKey('navrail_search'),
              icon: const Icon(Icons.search, size: 21),
              color: scheme.onSurface.withValues(alpha: 0.6),
              onPressed: () {
                context.go('/messages');
                ref.read(navRailSearchFocusProvider.notifier).state = true;
              },
            ),
          ),
          const SizedBox(height: 16),
          navItem(Icons.chat_bubble_outline, '消息', '/messages', 'navrail_messages'),
          navItem(Icons.auto_awesome_outlined, '万灵', '/wanling', 'navrail_wanling'),
          const Spacer(),
          // 账号切换:复用登录页 AccountSwitcher(外包 navrail_account key);
          // alwaysShow:savedLogins 为空也常驻入口(菜单提示暂无账号)
          const KeyedSubtree(
            key: ValueKey('navrail_account'),
            child: AccountSwitcher(iconOnly: true, alwaysShow: true),
          ),
        ],
      ),
    );
  }
}
