import 'package:flutter/material.dart';
import 'nav_rail.dart';

/// 三栏骨架第一层:左 36px 导航栏 + 内容区(内容区内部再分会话列表列+聊天区)。
class DesktopShell extends StatelessWidget {
  final Widget child;
  const DesktopShell({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          const NavRail(),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}
