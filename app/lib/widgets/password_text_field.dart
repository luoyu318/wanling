import 'package:flutter/material.dart';

/// 密码输入框：内置显隐切换（眼睛图标）。
///
/// 抽出来复用：登录页、修改密码页、切换账号/服务器列表编辑对话框共用，
/// 保持三处密码框样式一致。默认隐藏，点眼睛切换明文。
class PasswordTextField extends StatefulWidget {
  final TextEditingController? controller;
  final String? labelText;
  final String? hintText;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  const PasswordTextField({
    super.key,
    this.controller,
    this.labelText = '密码',
    this.hintText,
    this.focusNode,
    this.textInputAction,
    this.onSubmitted,
    this.autofocus = false,
  });

  @override
  State<PasswordTextField> createState() => _PasswordTextFieldState();
}

class _PasswordTextFieldState extends State<PasswordTextField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: widget.focusNode,
      obscureText: _obscure,
      autofocus: widget.autofocus,
      textInputAction: widget.textInputAction,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.labelText,
        hintText: widget.hintText,
        border: const OutlineInputBorder(),
        // 眼睛图标随显隐状态切换。off=当前隐藏，on=当前可见。
        suffixIcon: IconButton(
          icon: Icon(
              _obscure ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _obscure = !_obscure),
        ),
      ),
    );
  }
}
