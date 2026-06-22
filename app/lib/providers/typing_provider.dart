import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';
import 'chat_provider.dart' show wsProvider;

/// per-agentId typing 状态。
///
/// 订阅 ws.typingStream（TYPING_START 事件），收到时把对应 agentId 标 typing=true，
/// 同时启动 5 秒兜底 Timer（防 agent 卡死时永远显示 typing）。
///
/// agent 真实消息到达时由 ChatPage 调 clearTyping(agentId) 显式清掉。
class TypingNotifier extends StateNotifier<Map<String, bool>> {
  final Map<String, Timer> _timers = {};

  TypingNotifier() : super({});

  /// 标记 agentId 正在输入，5 秒兜底超时。
  void startTyping(String agentId) {
    state = {...state, agentId: true};
    _timers[agentId]?.cancel();
    _timers[agentId] = Timer(const Duration(seconds: 5), () {
      _clear(agentId);
    });
  }

  /// 显式清掉 typing（agent 真实消息到达时调）。
  void clearTyping(String agentId) {
    _clear(agentId);
  }

  void _clear(String agentId) {
    _timers[agentId]?.cancel();
    _timers.remove(agentId);
    if (!state.containsKey(agentId)) return;
    final next = Map<String, bool>.from(state)..remove(agentId);
    state = next;
  }

  @override
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    super.dispose();
  }
}

/// typingProvider：暴露 per-agentId typing 状态 map。
/// 订阅 ws.typingStream，过滤当前 user 的事件后调 startTyping。
final typingProvider =
    StateNotifierProvider<TypingNotifier, Map<String, bool>>((ref) {
  final ws = ref.watch(wsProvider);
  // 用 read 拿 auth 一次：避免 auth 变化重建 provider 导致 _timers 全丢
  final notifier = TypingNotifier();

  final sub = ws.typingStream.listen((d) {
    final auth = ref.read(authProvider);
    final eventUserId = d['user_id'] as String?;
    final agentId = d['agent_id'] as String?;
    if (eventUserId != auth.user?.id || agentId == null) return;
    notifier.startTyping(agentId);
  });
  ref.onDispose(sub.cancel);

  return notifier;
});
