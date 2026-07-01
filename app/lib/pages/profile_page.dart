import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../providers/auth_provider.dart';
import '../providers/friend_provider.dart';
import '../providers/saved_logins_provider.dart';
import '../utils/permission_helper.dart';
import '../widgets/avatar.dart';
import '../widgets/feedback/app_dialog.dart';
import '../widgets/settings_group.dart';
import '../widgets/settings_tile.dart';
import '../widgets/switch_account_sheet.dart';

/// 个人中心页：「我的」Tab。
/// 顶部用户区域背景与消息页 AppBar 一致（白底），列表用公共 SettingsTile。
class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage>
    with AutomaticKeepAliveClientMixin {
  String _version = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() {
      _version = 'v${info.version}+${info.buildNumber}';
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 必须调
    final user = ref.watch(authProvider).user;
    // 仅当有 2 个以上账号时才显示「切换账号」入口(单账号无切换意义)
    final showSwitchAccount = ref.watch(savedLoginsProvider).logins.length >= 2;
    // 收到的好友请求数,用于入口 tile 红点提示
    final incomingCount = ref.watch(friendIncomingCountProvider);

    // 与 AgentDetailPage 同款结构：CustomScrollView + SliverAppBar（覆盖 status bar）
    // + SliverToBoxAdapter（资料区）。样式/颜色保持自己的（#F7F7F7 + 黑字）。
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      body: CustomScrollView(
        slivers: [
          // SliverAppBar 自动占 status bar 区，背景与用户资料卡一致 #FFFFFF
          SliverAppBar(
            pinned: true,
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF111111),
            title: const Text(''),
          ),
          // 顶部用户区域：紧贴 AppBar 下方，无 top padding
          SliverToBoxAdapter(
            child: Container(
              color: Colors.white,
              padding:
                  const EdgeInsets.only(left: 16, right: 16, bottom: 24),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => context.push('/profile/edit'),
                    child: Avatar(
                      name: user?.displayName ?? '?',
                      url: user?.avatarUrl,
                      size: 60,
                      radius: 8,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user?.displayName ?? '未登录',
                          style: const TextStyle(
                            color: Color(0xFF111111),
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (user != null &&
                            user.bio != null &&
                            user.bio!.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            user.bio!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFF999999),
                              fontSize: 12,
                            ),
                          ),
                        ],
                        if (user != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            '注册于 ${user.createdAt.year}-'
                            '${user.createdAt.month.toString().padLeft(2, '0')}-'
                            '${user.createdAt.day.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                              color: Color(0xFF999999),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 设置项分组
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                // 我的好友入口:incoming 请求 > 0 时显示红点 Badge
                SettingsTile(
                  icon: Icons.people_outline,
                  label: '我的好友',
                  trailing: incomingCount > 0
                      ? Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFA5151),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          constraints: const BoxConstraints(minWidth: 16),
                          child: Text(
                            incomingCount > 99 ? '99+' : '$incomingCount',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        )
                      : const Icon(Icons.chevron_right,
                          size: 20, color: Color(0xFFC0C0C0)),
                  onTap: () => context.push('/friends'),
                ),
                // 设置内页（服务器地址配置）已移除，入口暂时隐藏。
                // 切换账号功能上线后，服务器地址改由「切换账号」管理。
                if (showSwitchAccount)
                  SettingsTile(
                    icon: Icons.swap_horiz,
                    label: '切换账号',
                    onTap: () => showSwitchAccountSheet(context),
                  ),
                SettingsTile(
                  icon: Icons.notifications_outlined,
                  label: '通知与后台',
                  onTap: () =>
                      PermissionHelper.openAppNotificationSettings(),
                ),
                SettingsTile(
                  icon: Icons.lock_outline,
                  label: '修改密码',
                  onTap: () => context.push('/change-password'),
                ),
                SettingsTile(
                  icon: Icons.info_outline,
                  label: '关于',
                  trailing: Text(
                    _version,
                    style: const TextStyle(
                        color: Color(0xFF999999), fontSize: 12),
                  ),
                  onTap: () => context.push('/about'),
                ),
              ],
            ),
          ),
          // 退出登录（单独一组）
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.logout,
                  label: '退出登录',
                  labelColor: const Color(0xFFFA5151),
                  iconColor: const Color(0xFFFA5151),
                  showDivider: false,
                  onTap: () => _confirmLogout(context, ref),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 退出登录二次确认。点击「退出」会清 token 并回到登录页。
  void _confirmLogout(BuildContext context, WidgetRef ref) {
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
}

