import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import '../utils/dio_error.dart';
import '../widgets/account_picker_dialog.dart';

/// 桌面登录页:已存账号卡片列表(点击直接登录 + 删除) + 「添加服务器」弹框
/// + 手动登录表单(服务器地址/用户名/密码/记住账号)。
///
/// 服务器地址流程与 app 壳一致:预填上次值(savedLogins.selected 优先,
/// 退回 settingsProvider 持久化的 baseUrl),提交前 setBaseUrl 同步
/// settingsProvider → apiProvider 重建 → authProvider.setApi 更新引用。
class DesktopLoginPage extends ConsumerStatefulWidget {
  const DesktopLoginPage({super.key});

  @override
  ConsumerState<DesktopLoginPage> createState() => _DesktopLoginPageState();
}

class _DesktopLoginPageState extends ConsumerState<DesktopLoginPage> {
  final _serverCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _remember = true;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 首帧后同步 controller(避免 build 副作用),预填上次使用的地址/凭据
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selected = ref.read(savedLoginsProvider).selected;
      _serverCtrl.text = selected?.server ?? ref.read(settingsProvider);
      if (selected != null) {
        _usernameCtrl.text = selected.username;
        _passwordCtrl.text = selected.password;
      }
    });
  }

  @override
  void dispose() {
    _serverCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final savedLogins = ref.watch(savedLoginsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: theme.dividerColor),
                boxShadow: [
                  BoxShadow(
                    color: theme.shadowColor.withValues(alpha: 0.05),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 40,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '万灵',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '唤灵 · 即应',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                  // 切换服务器/账号入口(对齐 app 登录页):单独按钮,
                  // 点击弹出账号选择列表(点卡片直登/删除/添加)。
                  if (savedLogins.logins.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      key: const ValueKey('login_switch_account'),
                      onPressed: () => showAccountPickerDialog(context, ref),
                      icon: const Icon(Icons.swap_horiz, size: 18),
                      label: const Text('切换服务器/账号'),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Divider(color: theme.dividerColor),
                  const SizedBox(height: 12),
                  Text(
                    '手动登录',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('login_server_field'),
                    controller: _serverCtrl,
                    decoration: const InputDecoration(
                      labelText: '服务器地址',
                      border: OutlineInputBorder(),
                      hintText: 'http://your-server:18008',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('login_username_field'),
                    controller: _usernameCtrl,
                    autofillHints: const [AutofillHints.username],
                    decoration: const InputDecoration(
                      labelText: '用户名',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('login_password_field'),
                    controller: _passwordCtrl,
                    obscureText: _obscure,
                    onSubmitted: (_) => auth.isLoading ? null : _submit(),
                    decoration: InputDecoration(
                      labelText: '密码',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () => setState(() => _remember = !_remember),
                    borderRadius: BorderRadius.circular(4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 40,
                          child: Checkbox(
                            value: _remember,
                            onChanged: (v) =>
                                setState(() => _remember = v ?? true),
                          ),
                        ),
                        const Text('记住账号'),
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      key: const ValueKey('login_error_line'),
                      style: TextStyle(
                        color: theme.colorScheme.error,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: auth.isLoading ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: auth.isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('登录'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _submit() async {
    setState(() => _error = null);
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    // 规范化 + 校验(防 http:host:port 形态进 provider 树致灰屏)。
    final server = normalizeBaseUrl(_serverCtrl.text);
    if (server.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error =
          server.isEmpty ? '服务器地址无效' : '请填写完整');
      return;
    }
    // 同步 baseUrl(settingsProvider → apiProvider 重建 → auth.setApi)
    await ref.read(settingsProvider.notifier).setBaseUrl(server);
    try {
      await ref.read(authProvider.notifier).login(username, password);
      if (_remember) {
        // 登录成功后存入 savedLogins(同 server+username 去重或更新密码)
        await ref
            .read(savedLoginsProvider.notifier)
            .saveOrAdd(server, username, password);
      }
      if (mounted) context.go('/messages');
    } catch (e) {
      if (mounted) setState(() => _error = extractDioErrorMessage(e));
    }
  }

}
