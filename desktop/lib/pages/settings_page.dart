import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import '../providers/desktop_notifications_provider.dart';
import '../providers/settings_nav_provider.dart';
import '../providers/theme_mode_provider.dart';

/// 设置页(右卡片):外观(主题)/通用(服务器地址 + 通知开关)/账号(登出)/关于。
///
/// 与左卡片 [SettingsNavPane] 经 provider 双向联动:
/// - 监听 [settingsScrollToProvider] 脉冲 → animateTo 对应分区;
/// - 滚动时按分区 offset 反推当前分区 → 写 [settingsActiveSectionProvider]。
///
/// - 服务器地址:只读展示 core settingsProvider(api_base_url),
///   点按弹窗输入新值 setBaseUrl(登录页同源存储);
/// - 通知开关:desktopNotificationsProvider 持久化,控制桌面系统通知出口;
/// - 登出:确认对话框 → authProvider.logout()(失败也置未登录态,
///   router redirect 自动跳 /login)。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _scroll = ScrollController();
  final _sectionKeys = List.generate(4, (_) => GlobalKey());

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 首帧布局完成后处理已 pending 的定位脉冲(如从导航点进)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _onScroll();
      final pending = ref.read(settingsScrollToProvider);
      if (pending != null) _consumeScrollTo(pending);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// 消费定位脉冲:滚动到分区 i(带 appbar 锚定偏移),消费后清零。
  /// 懒构建兜底:目标段在视口外未布局(key 无 context)时先同步 jumpTo
  /// 尾部强制布局,postFrame 后二次精确定位(jumpTo 同步无动画,不循环)。
  void _consumeScrollTo(int i) {
    final ctx = _sectionKeys[i].currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    final scrollBox = context.findRenderObject() as RenderBox?;
    if (scrollBox == null || !_scroll.hasClients) return;
    if (box == null) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pending = ref.read(settingsScrollToProvider);
        if (pending != null) _consumeScrollTo(pending);
      });
      return;
    }
    final target = box.localToGlobal(Offset.zero, ancestor: scrollBox).dy +
        _scroll.offset -
        8;
    _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
    ref.read(settingsScrollToProvider.notifier).state = null;
  }

  /// 滚动反推当前分区:最后一个「分区头 offset <= 滚动位置 + 锚定阈值」
  /// 的分区为活跃区(与左侧导航高亮联动)。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final scrollBox = context.findRenderObject() as RenderBox?;
    if (scrollBox == null) return;
    var active = 0;
    for (var i = 0; i < _sectionKeys.length; i++) {
      final box =
          _sectionKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final top =
          box.localToGlobal(Offset.zero, ancestor: scrollBox).dy;
      // 分区头进入视口顶部 96px 锚定带内即视为活跃。
      if (top <= 96) active = i;
    }
    // 滚到底(最后分区天然贴不了顶):活跃 = 最后分区。
    if (_scroll.offset >= _scroll.position.maxScrollExtent - 1) {
      active = _sectionKeys.length - 1;
    }
    if (ref.read(settingsActiveSectionProvider) != active) {
      ref.read(settingsActiveSectionProvider.notifier).state = active;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 左侧导航点击脉冲 → 滚动定位(消费后清零,防重复触发)。
    ref.listen(settingsScrollToProvider, (prev, next) {
      if (next != null) _consumeScrollTo(next);
    });

    final mode = ref.watch(themeModeProvider);
    final user = ref.watch(authProvider.select((s) => s.user));
    final baseUrl = ref.watch(settingsProvider);
    final notifications = ref.watch(desktopNotificationsProvider);

    Widget sectionHeader(int i, String title) => Padding(
          key: _sectionKeys[i],
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        controller: _scroll,
        children: [
          sectionHeader(0, '外观'),
          RadioGroup<ThemeMode>(
            groupValue: mode,
            onChanged: (v) => ref
                .read(themeModeProvider.notifier)
                .setMode(v ?? ThemeMode.light),
            child: const Column(
              children: [
                RadioListTile<ThemeMode>(
                  value: ThemeMode.light,
                  title: Text('浅色'),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.dark,
                  title: Text('深色'),
                ),
                RadioListTile<ThemeMode>(
                  value: ThemeMode.system,
                  title: Text('跟随系统'),
                ),
              ],
            ),
          ),
          sectionHeader(1, '通用'),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('服务器地址'),
            subtitle: Text(baseUrl),
            onTap: () => _editBaseUrl(context, ref, baseUrl),
          ),
          SwitchListTile(
            key: const ValueKey('notif_switch'),
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('桌面通知'),
            subtitle: const Text('收到新消息时弹出系统通知'),
            value: notifications,
            onChanged: (v) =>
                ref.read(desktopNotificationsProvider.notifier).setEnabled(v),
          ),
          sectionHeader(2, '账号'),
          ListTile(
            leading: const Icon(Icons.account_circle),
            title: Text(user?.nickname ?? user?.username ?? '未登录'),
            subtitle: user != null ? Text('@${user.username}') : null,
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('退出登录'),
            onTap: () => _confirmLogout(context, ref),
          ),
          sectionHeader(3, '关于'),
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('万灵 Wanling'),
            subtitle: Text('版本 1.5.0'),
          ),
          const ListTile(
            leading: Icon(Icons.description_outlined),
            title: Text('说明'),
            subtitle: Text('AI Agent 聊天系统桌面端'),
          ),
        ],
      ),
    );
  }

  /// 弹窗修改服务器地址:TextField 预填当前值,保存写 settingsProvider。
  void _editBaseUrl(BuildContext context, WidgetRef ref, String current) {
    final ctrl = TextEditingController(text: current);
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改服务器地址'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'https://your-server:18008',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final url = ctrl.text.trim();
              if (url.isEmpty) return;
              ref.read(settingsProvider.notifier).setBaseUrl(url);
              Navigator.of(dialogContext).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 登出确认:防误触(登出会清本地会话态,重进需重输密码)。
  void _confirmLogout(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('确定要退出当前账号吗?退出后需重新登录。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              ref.read(authProvider.notifier).logout();
            },
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }
}
