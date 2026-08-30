import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/theme/app_colors.dart';
import '../utils/permission_helper.dart';
import '../widgets/avatar.dart';
import '../widgets/feedback/app_dialog.dart';
import '../widgets/settings_tile.dart';

/// 侧滑栏主面板（方案 B 双层的右侧区域）。
/// 原「我的」页(ProfilePage)菜单整段迁移至此:编辑资料/通知与后台/
/// 修改密码/关于(版本号)/退出登录钉底。头部(头像+昵称+简介)点击进编辑资料。
class SidebarProfilePanel extends ConsumerStatefulWidget {
  const SidebarProfilePanel({super.key});

  @override
  ConsumerState<SidebarProfilePanel> createState() =>
      _SidebarProfilePanelState();
}

class _SidebarProfilePanelState extends ConsumerState<SidebarProfilePanel> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _version = 'v${info.version}+${info.buildNumber}');
  }

  void _confirmLogout() {
    showAppDialog(
      context: context,
      title: '退出登录',
      content: const Text('确定要退出吗？'),
      confirmText: '退出',
      onConfirm: () {
        ref.read(authProvider.notifier).logout();
        if (context.mounted) context.go('/login');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).user;
    // 极小屏防溢出:头部 + 菜单超出可视高度时可滚动;
    // SliverFillRemaining 让剩余空间填充(「退出登录」钉底),内容超长时自然滚动
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // —— 头部:头像居左,昵称 + 简介(裸文字)居右,整块点击进编辑资料 ——
              GestureDetector(
                onTap: () => context.push('/profile/edit'),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                  child: Row(
                    children: [
                      Avatar(
                        name: user?.displayName ?? '?',
                        url: user?.avatarUrl,
                        size: 64,
                        radius: 14,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.displayName ?? '未登录',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w700,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              (user?.bio != null && user!.bio!.isNotEmpty)
                                  ? user.bio!
                                  : '输入你的个性签名...',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 4),
              // —— 菜单区(原 ProfilePage 设置项):彩色图标区分功能,无分割线无箭头 ——
              SettingsTile(
                icon: Icons.person,
                iconColor: const Color(0xFF2F6BFF),
                label: '编辑资料',
                showDivider: false,
                showChevron: false,
                onTap: () => context.push('/profile/edit'),
              ),
              SettingsTile(
                icon: Icons.notifications,
                iconColor: const Color(0xFFFF9500),
                label: '通知与后台',
                showDivider: false,
                showChevron: false,
                onTap: () => PermissionHelper.openAppNotificationSettings(),
              ),
              SettingsTile(
                icon: Icons.lock,
                iconColor: const Color(0xFF00B578),
                label: '修改密码',
                showDivider: false,
                showChevron: false,
                onTap: () => context.push('/change-password'),
              ),
              SettingsTile(
                icon: Icons.info,
                iconColor: const Color(0xFF7A5AF8),
                label: '关于',
                showDivider: false,
                showChevron: false,
                trailing: Text(
                  _version,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                onTap: () => context.push('/about'),
              ),
            ],
          ),
        ),
        // 剩余空间填充:内容不足一屏时「退出登录」钉底,内容超长时随滚动下移
        SliverFillRemaining(
          hasScrollBody: false,
          child: Column(
            children: [
              const Spacer(),
              SettingsTile(
                icon: Icons.logout,
                label: '退出登录',
                labelColor: AppColors.danger,
                iconColor: AppColors.danger,
                showDivider: false,
                showChevron: false,
                onTap: _confirmLogout,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
