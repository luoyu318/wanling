import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/chat_provider.dart' show wsProvider;
import '../services/websocket_service.dart';

/// 顶部断线提示 banner。
///
/// 监听 wsProvider 的连接状态流，断开时显示橙色 MaterialBanner，
/// 「实时连接已断开，正在重试...」。连接恢复后自动消失。
class ConnectionBanner extends ConsumerStatefulWidget {
  const ConnectionBanner({super.key});

  @override
  ConsumerState<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  StreamSubscription<ConnState>? _sub;
  ConnState _state = ConnState.disconnected;

  @override
  void initState() {
    super.initState();
    final ws = ref.read(wsProvider);
    _state = ws.currentConnState;
    _sub = ws.connectionStateStream.listen((s) {
      if (!mounted) return;
      setState(() => _state = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_state == ConnState.connected) return const SizedBox.shrink();
    return MaterialBanner(
      content: const Row(
        children: [
          Icon(Icons.cloud_off, size: 16, color: Colors.white),
          SizedBox(width: 12),
          Text(
            '实时连接已断开，正在重试...',
            style: TextStyle(color: Colors.white, fontSize: 13),
          ),
        ],
      ),
      backgroundColor: const Color(0xFFE8842C),
      actions: const [SizedBox.shrink()],
    );
  }
}
