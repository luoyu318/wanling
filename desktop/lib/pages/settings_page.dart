import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import '../providers/desktop_notifications_provider.dart';
import '../providers/theme_mode_provider.dart';

/// 设置页:外观(主题)/通用(服务器地址 + 通知开关)/账号(登出)/关于。
///
/// - 服务器地址:只读展示 core settingsProvider(api_base_url),
///   点按弹窗输入新值 setBaseUrl(登录页同源存储);
/// - 通知开关:desktopNotificationsProvider 持久化,控制桌面系统通知出口;
/// - 登出:确认对话框 → authProvider.logout()(失败也置未登录态,
///   router redirect 自动跳 /login)。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final user = ref.watch(authProvider.select((s) => s.user));
    final baseUrl = ref.watch(settingsProvider);
    final notifications = ref.watch(desktopNotificationsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('外观', style: Theme.of(context).textTheme.titleSmall),
          ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('通用', style: Theme.of(context).textTheme.titleSmall),
          ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('账号', style: Theme.of(context).textTheme.titleSmall),
          ),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text('关于', style: Theme.of(context).textTheme.titleSmall),
          ),
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
