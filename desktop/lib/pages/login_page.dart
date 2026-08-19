import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 登录页占位:仅提供跳转入口,真实登录页 Task 4 替换。
class DesktopLoginPage extends StatelessWidget {
  const DesktopLoginPage({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => context.go('/messages'),
          child: const Text('登录'),
        ),
      ),
    );
  }
}
