import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import '../utils/snackbar.dart';

/// 设置页：当前仅支持服务器地址（baseUrl）配置。
/// 修改后提示「重新登录生效」，因 apiProvider watch 本设置，
/// 后续登录会拿到新 baseUrl；WS 同样依赖登录后的连接。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    // 从 provider 读初始值；用 read 而非 watch，避免重建时重置输入。
    _ctrl = TextEditingController(text: ref.read(settingsProvider));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBgLight,
      appBar: AppBar(title: const Text('设置')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('服务器地址', style: TextStyle(fontSize: 13, color: Color(0xFF999999))),
            const SizedBox(height: 8),
            TextField(
              controller: _ctrl,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'http://localhost:18008',
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  ref.read(settingsProvider.notifier).setBaseUrl(_ctrl.text.trim());
                  showAppSnackBar(context, '已保存，重新登录生效', type: SnackBarType.success);
                },
                child: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
