import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../theme/app_colors.dart';
import '../utils/dio_error.dart';
import '../utils/snackbar.dart';

/// 修改密码页：新密码 + 确认密码 + 提交。
///
/// 不需要旧密码（JWT 已验证身份）。提交成功后弹 toast 并 pop 回 Profile。
/// 不强制重登，由用户决定。
class ChangePasswordPage extends ConsumerStatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  ConsumerState<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends ConsumerState<ChangePasswordPage> {
  final _newPwdCtrl = TextEditingController();
  final _confirmPwdCtrl = TextEditingController();
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _submitting = false;

  @override
  void dispose() {
    _newPwdCtrl.dispose();
    _confirmPwdCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.pageBgLight,
      appBar: AppBar(title: const Text('修改密码')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _newPwdCtrl,
              obscureText: _obscureNew,
              decoration: InputDecoration(
                labelText: '新密码',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureNew
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () => setState(() => _obscureNew = !_obscureNew),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmPwdCtrl,
              obscureText: _obscureConfirm,
              decoration: InputDecoration(
                labelText: '确认密码',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscureConfirm
                      ? Icons.visibility_off
                      : Icons.visibility),
                  onPressed: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('提交'),
            ),
          ],
        ),
      ),
    );
  }

  void _submit() async {
    final newPwd = _newPwdCtrl.text;
    final confirmPwd = _confirmPwdCtrl.text;

    if (newPwd.length < 6) {
      showAppSnackBar(context, '密码至少 6 位', type: SnackBarType.error);
      return;
    }
    if (newPwd != confirmPwd) {
      showAppSnackBar(context, '两次输入不一致', type: SnackBarType.error);
      return;
    }

    setState(() => _submitting = true);
    try {
      await ref.read(authProvider.notifier).changePassword(newPwd);
      if (mounted) {
        showAppSnackBar(context, '密码已修改', type: SnackBarType.success);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          extractDioErrorMessage(e),
          type: SnackBarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
