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
/// 修改密码/关于(版本号)/退出登录。头部签名 pill 点击进编辑资料。
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // —— 头部:大头像 + 名字 + server 副标题 + 签名 pill ——
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: () => context.push('/profile/edit'),
                    child: Avatar(
                      name: user?.displayName ?? '?',
                      url: user?.avatarUrl,
                      size: 64,
                      radius: 14,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => context.push('/profile/edit'),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF7F7F7),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        (user?.bio != null && user!.bio!.isNotEmpty)
                            ? user.bio!
                            : '输入你的个性签名...',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                user?.displayName ?? '未登录',
                style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary),
              ),
              const SizedBox(height: 2),
              Text(
                user != null ? '注册于 ${user.createdAt.year}' : '',
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1, color: AppColors.divider),
        // —— 菜单区（原 ProfilePage 设置项）——
        SettingsTile(
          icon: Icons.person_outline,
          label: '编辑资料',
          onTap: () => context.push('/profile/edit'),
        ),
        SettingsTile(
          icon: Icons.notifications_outlined,
          label: '通知与后台',
          onTap: () => PermissionHelper.openAppNotificationSettings(),
        ),
        SettingsTile(
          icon: Icons.lock_outline,
          label: '修改密码',
          onTap: () => context.push('/change-password'),
        ),
        SettingsTile(
          icon: Icons.info_outline,
          label: '关于',
          trailing: Text(_version,
              style: const TextStyle(
                  color: AppColors.textSecondary, fontSize: 12)),
          onTap: () => context.push('/about'),
        ),
        SettingsTile(
          icon: Icons.logout,
          label: '退出登录',
          labelColor: AppColors.danger,
          iconColor: AppColors.danger,
          showDivider: false,
          onTap: _confirmLogout,
        ),
      ],
    );
  }
}
