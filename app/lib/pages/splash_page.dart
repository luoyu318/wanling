import 'package:flutter/material.dart';

/// 启动占位页：在 restoreSession 完成前 router 会把所有路径 redirect 到这里。
/// 避免冷启动期间因 auth 状态未定而闪现 /login。
class SplashPage extends StatelessWidget {
  const SplashPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
