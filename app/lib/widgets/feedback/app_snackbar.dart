import 'dart:async';

import 'package:flutter/material.dart';

import '../../utils/snackbar.dart' show SnackBarType;

/// 全局统一位置的轻量提示条。
///
/// 位置策略：不再依赖 inputBarKey，统一用 SafeArea bottom 80px 让提示条
/// 在所有页面（含没有 MessageInputBar 的页面如 AgentDetailPage）都距底部
/// 一致距离（避开 home indicator + 合理视觉间距）。
/// 风格：深色胶囊 #2C2C2E(0.9) + 白字 + 圆角 10 + 左侧 logo。
/// 自动 2s 消失。
///
/// API 与 lib/utils/snackbar.dart 完全一致（调用方零改动），
/// 旧文件保留为转发包装，便于已存在的 20+ 处调用继续工作。
void showAppSnackBar(BuildContext context, String message,
    {SnackBarType type = SnackBarType.info}) {
  final overlay = Overlay.of(context, rootOverlay: true);

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _AppSnackBarView(
      message: message,
      type: type,
      onDismiss: () {
        if (entry.mounted) entry.remove();
      },
    ),
  );

  overlay.insert(entry);
}

class _AppSnackBarView extends StatefulWidget {
  final String message;
  final SnackBarType type;
  final VoidCallback onDismiss;

  const _AppSnackBarView({
    required this.message,
    required this.type,
    required this.onDismiss,
  });

  @override
  State<_AppSnackBarView> createState() => _AppSnackBarViewState();
}

class _AppSnackBarViewState extends State<_AppSnackBarView> {
  /// 提示条显示时长。
  static const Duration _showDuration = Duration(seconds: 2);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(_showDuration, widget.onDismiss);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        minimum: const EdgeInsets.fromLTRB(40, 0, 40, 80),
        child: Center(
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xE62C2C2E),
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x40000000),
                    blurRadius: 12,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Image.asset(
                    'assets/images/logo.png',
                    width: 24,
                    height: 24,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    widget.message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
