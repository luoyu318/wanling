import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/saved_login.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import '../utils/dio_error.dart';
import '../widgets/add_account_dialog.dart';

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
                  // 已存账号卡片列表(对齐 app select_account_page):
                  // 点击直接用保存凭据登录,尾部删除按钮。
                  if (savedLogins.logins.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    ..._buildAccountCards(savedLogins, theme),
                  ],
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const ValueKey('login_add_account'),
                    onPressed: () => showAddAccountDialog(context, ref),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加服务器'),
                  ),
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

  /// 已存账号卡片行:username@server + 备注,点击 loginWith 直接登录。
  List<Widget> _buildAccountCards(SavedLoginsState savedLogins, ThemeData theme) {
    final busy = ref.watch(
      authProvider.select((s) => s.isSwitching || s.isLoading),
    );
    return [
      Text(
        '点击账号直接登录',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
      const SizedBox(height: 8),
      for (var i = 0; i < savedLogins.logins.length; i++)
        Card(
          margin: const EdgeInsets.only(bottom: 8),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: i == savedLogins.selectedIndex
                  ? theme.colorScheme.primary
                  : theme.dividerColor,
            ),
          ),
          child: ListTile(
            dense: true,
            enabled: !busy,
            leading: Icon(
              Icons.account_circle,
              size: 28,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              '${savedLogins.logins[i].username}@${savedLogins.logins[i].server}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            subtitle: (savedLogins.logins[i].label ?? '').isNotEmpty
                ? Text(
                    savedLogins.logins[i].label!,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  )
                : null,
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: '删除',
              onPressed: () => _confirmRemove(i, savedLogins.logins[i]),
            ),
            onTap: busy ? null : () => _loginWith(i),
          ),
        ),
    ];
  }

  /// 用保存凭据直接登录(loginWith 内部同步 baseUrl → 登录 → 跳转)。
  Future<void> _loginWith(int index) async {
    setState(() => _error = null);
    try {
      await ref.read(savedLoginsProvider.notifier).loginWith(index);
      if (mounted) context.go('/messages');
    } catch (e) {
      if (mounted) setState(() => _error = extractDioErrorMessage(e));
    }
  }

  Future<void> _confirmRemove(int index, SavedLogin login) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确认删除 ${login.username} @ ${login.server}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(savedLoginsProvider.notifier).remove(index);
    }
  }

  void _submit() async {
    setState(() => _error = null);
    final server = _serverCtrl.text.trim();
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (server.isEmpty || username.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写完整');
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
