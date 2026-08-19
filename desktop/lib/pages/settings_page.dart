import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import '../providers/theme_mode_provider.dart';

/// 设置页:外观主题切换段(浅色/深色/跟随系统)+ 账号段(登出)。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final user = ref.watch(authProvider.select((s) => s.user));
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
            onTap: () => ref.read(authProvider.notifier).logout(),
          ),
        ],
      ),
    );
  }
}
