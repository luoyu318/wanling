import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/saved_logins_provider.dart';
import '../providers/settings_provider.dart';
import '../theme/app_colors.dart';
import '../utils/dio_error.dart';
import '../utils/snackbar.dart';
import '../widgets/password_text_field.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _serverCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();

  @override
  void dispose() {
    _serverCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 监听 savedLogins:从 SelectAccountPage 返回或启动预填时自动更新表单
    final savedState = ref.watch(savedLoginsProvider);
    final selected = savedState.selected;
    if (selected != null) {
      _serverCtrl.text = selected.server;
      _usernameCtrl.text = selected.username;
      _passwordCtrl.text = selected.password;
    }
    final auth = ref.watch(authProvider);

    return Scaffold(
      backgroundColor: AppColors.pageBgLight,
      appBar: AppBar(title: const Text('登录')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              // Logo 区
              Icon(Icons.auto_awesome,
                  size: 56, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 8),
              const Text('万灵',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(fontSize: 18, fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              const Text('唤灵 · 即应',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
              const SizedBox(height: 32),
              // 主表单
              TextField(
                controller: _serverCtrl,
                decoration: const InputDecoration(
                    labelText: '服务器地址',
                    border: OutlineInputBorder(),
                    hintText: 'https://your-server.com',
                    hintStyle: TextStyle(color: Color(0xFFBBBBBB))),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                    labelText: '用户名', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              PasswordTextField(
                controller: _passwordCtrl,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => auth.isLoading ? null : _submit(),
              ),
              const SizedBox(height: 24),
              // 登录按钮(选中态高亮)
              FilledButton(
                onPressed: auth.isLoading ? null : _submit,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: auth.isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(selected != null ? '点此登录' : '登录'),
              ),
              // 切换入口(有记录时显示)
              if (savedState.logins.isNotEmpty) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _goToSelectAccount,
                  icon: const Icon(Icons.swap_horiz, size: 18),
                  label: const Text('切换服务器/账号'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _goToSelectAccount() {
    context.push('/select-account');
  }

  void _submit() async {
    final server = _serverCtrl.text.trim();
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (server.isEmpty || username.isEmpty || password.isEmpty) {
      showAppSnackBar(context, '请填写完整');
      return;
    }
    // 同步 baseUrl 到 settingsProvider(apiProvider 重建 → authProvider.setApi 更新引用)
    await ref.read(settingsProvider.notifier).setBaseUrl(server);
    final notifier = ref.read(authProvider.notifier);
    try {
      await notifier.login(username, password);
      // 登录成功后存入 savedLogins(去重或更新密码)
      await ref
          .read(savedLoginsProvider.notifier)
          .saveOrAdd(server, username, password);
      if (mounted) {
        showAppSnackBar(context, '登录成功', type: SnackBarType.success);
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, extractDioErrorMessage(e),
            type: SnackBarType.error);
      }
    }
  }
}
