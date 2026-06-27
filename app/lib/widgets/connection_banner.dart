import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../services/websocket_service.dart';

/// 顶部断线提示 banner。
///
/// 仅在「持续断线超过 [_delay]」时显示「实时连接已断开，正在重试...」。
///
/// 去抖设计（解决切换/登录时 banner 闪一下）：
/// 切换账号或登录时，token 变化会让旧 WS dispose（发 disconnected）再建新 WS
/// （connect→connecting→connected）。旧 disconnected 只是中间态，几百 ms 就过去。
/// 若 banner 立即响应会闪一下橙色条。改为：看到 disconnected 启动 3s 定时器，
/// 期间收到 connecting/connected 就取消，只有持续断线 3s 才提示。
///
/// 另有两层静默兜底（即便没到定时器也不显示）：
/// 1. 连接进行中（connecting）：握手是正常预期，不是故障。
/// 2. 认证过渡期（isSwitching/isRestoring/isLoading）：token 切换/恢复/登录中，
///    断开是必然的预期态。
///
/// 通过 [connStateProvider] 间接订阅 wsProvider：切换账号时 wsProvider 重建，
/// connStateProvider 跟随重建订阅新实例的状态流，避免监听已 dispose 的旧实例。
class ConnectionBanner extends ConsumerStatefulWidget {
  const ConnectionBanner({super.key});

  @override
  ConsumerState<ConnectionBanner> createState() => _ConnectionBannerState();
}

class _ConnectionBannerState extends ConsumerState<ConnectionBanner> {
  /// 断线持续多久后才提示。切换/登录的中间态 disconnected 通常几百 ms，
  /// 3s 足够过滤掉；真正断线（网络断/服务端挂）会持续超过此阈值。
  static const _delay = Duration(seconds: 3);

  Timer? _timer;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    // 用 listenManual 而非 build 内驱动定时器：副作用放在状态变化回调里更干净，
    // 避免 build 频繁执行时反复创建/取消 Timer。两个监听任一变化都重新评估。
    // fireImmediately=true:首帧立即按当前状态评估；loading(valueOrNull=null)
    // 时 _isDown 返回 false 不会 setState，挂载瞬间安全。
    ref.listenManual<AsyncValue<ConnState>>(connStateProvider, (prev, next) {
      _evaluate(next);
    }, fireImmediately: true);
    ref.listenManual<AuthState>(authProvider, (prev, next) {
      _evaluate(ref.read(connStateProvider));
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 判定当前是否处于「真正断线」状态。
  /// loading（无值）视为未知，不算断线，避免 StreamProvider 重建瞬间误判。
  bool _isDown(AsyncValue<ConnState> connState) {
    final s = connState.valueOrNull;
    if (s == null) return false; // loading/未知:不提示
    if (s == ConnState.connecting) return false;
    if (s == ConnState.connected) return false;
    final auth = ref.read(authProvider);
    if (auth.isSwitching || auth.isRestoring || auth.isLoading) return false;
    return true; // disconnected 且非过渡期
  }

  void _evaluate(AsyncValue<ConnState> connState) {
    final down = _isDown(connState);
    if (down) {
      // 进入断线:启动延迟定时器,到期才显示。已在计时中不重复启动。
      _timer ??= Timer(_delay, () {
        if (mounted) setState(() => _show = true);
      });
    } else {
      // 恢复(连接中/已连接/进入过渡期/loading):取消计时,立即隐藏。
      if (_timer != null || _show) {
        _timer?.cancel();
        _timer = null;
        if (_show) setState(() => _show = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();
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
