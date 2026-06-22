import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../providers/auth_provider.dart';
import '../utils/permission_helper.dart';
import '../widgets/avatar.dart';

/// 个人中心页：「我的」Tab。
/// 顶部用户区域背景与消息页 AppBar 一致（#F7F7F7），列表用自定义 _ProfileTile。
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
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                children: [
                  _ProfileTile(
                    icon: Icons.settings_outlined,
                    label: '设置',
                    trailing: _chevron,
                    onTap: () => context.push('/settings'),
                  ),
                  _ProfileTile(
                    icon: Icons.notifications_outlined,
                    label: '通知与后台',
                    trailing: _chevron,
                    onTap: () =>
                        PermissionHelper.openAppNotificationSettings(),
                  ),
                  _ProfileTile(
                    icon: Icons.lock_outline,
                    label: '修改密码',
                    trailing: _chevron,
                    onTap: () => context.push('/change-password'),
                  ),
                  _ProfileTile(
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
          ),
          // 退出登录（单独一组）
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _ProfileTile(
                icon: Icons.logout,
                label: '退出登录',
                labelColor: const Color(0xFFFA5151),
                iconColor: const Color(0xFFFA5151),
                showDivider: false,
                onTap: () => _confirmLogout(context, ref),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 退出登录二次确认。点击「退出」会清 token 并回到登录页。
  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(authProvider.notifier).logout();
              Navigator.pop(ctx); // 关 dialog
              if (context.mounted) context.go('/login');
            },
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }
}

/// 「我的」页列表项。按下背景反馈 #EDEDED，底部画分割线 #E4E4E4（左对齐 icon 右侧）。
/// 与 _ConvTile / _AgentTile 同款按下反馈模式：Listener 立即变色 + InkWell 透明 splash。

// chevron：size 20（比默认 24 细，不加重视觉）。
// 距离屏幕右边缘 = Container padding right = 10（由 _ProfileTile 控制）。
const _chevron = Icon(Icons.chevron_right, size: 20, color: Color(0xFFC0C0C0));
class _ProfileTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? labelColor;
  final Color? iconColor;
  final bool showDivider;

  const _ProfileTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.trailing,
    this.labelColor,
    this.iconColor,
    this.showDivider = true,
  });

  @override
  State<_ProfileTile> createState() => _ProfileTileState();
}

class _ProfileTileState extends State<_ProfileTile> {
  bool _isPressed = false;
  Offset? _downPos; // 记录按下位置，用于检测滑动距离

  void _setPressed(bool v) {
    if (_isPressed == v) return;
    setState(() => _isPressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final tileBg =
        _isPressed ? const Color(0xFFEDEDED) : Colors.white;

    return Listener(
      onPointerDown: (e) {
        _downPos = e.position;
        _setPressed(true);
      },
      // 滑动超过 8px 视为滚动而非点击，立即归位避免背景色卡住
      onPointerMove: (e) {
        if (_downPos != null &&
            (e.position - _downPos!).distance > 8) {
          _setPressed(false);
        }
      },
      onPointerUp: (_) {
        _downPos = null;
        _setPressed(false);
      },
      onPointerCancel: (_) {
        _downPos = null;
        _setPressed(false);
      },
      child: InkWell(
        onTap: widget.onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Column(
          children: [
            Container(
              color: tileBg,
              // right 10 让 chevron 距离屏幕右边缘 10（chevron 无内 padding）
              padding: const EdgeInsets.only(
                  left: 16, right: 10, top: 14, bottom: 14),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: 22,
                    color: widget.iconColor ?? const Color(0xFF333333),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w300, // w300 细体
                        color: widget.labelColor ?? const Color(0xFF333333),
                      ),
                    ),
                  ),
                  if (widget.trailing != null) ...[
                    const SizedBox(width: 8),
                    widget.trailing!,
                  ],
                ],
              ),
            ),
            if (widget.showDivider)
              // 分割线区域：白色与 tile 同色无缝；线段从 left=56 开始
              // 56 = 16 padding + 22 icon + 18 spacing 修正 ≈ 与文字对齐
              Container(
                height: 0.5,
                color: Colors.white,
                child: Container(
                  margin: const EdgeInsets.only(left: 54),
                  color: const Color(0xFFE4E4E4),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
