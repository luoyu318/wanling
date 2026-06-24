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
///
/// 订阅两条流：
/// - ws.typingStream（TYPING_START）→ startTyping：标记 agent 在输入
/// - ws.messages（MESSAGE_CREATE from agent）→ clearTyping：收到 agent 真实消息就清掉
///
/// clearTyping 放在全局 provider 而非 ChatPage，是为了「用户离开 ChatPage 后
/// typing 也能被正确清除」——ChatPage 的 _msgSub 会随页面 dispose 失效，
/// 导致 typing 卡在 true（仅靠 5s 兜底 timer 不可靠，与消息流时序不同步时会卡死）。
final typingProvider =
    StateNotifierProvider<TypingNotifier, Map<String, bool>>((ref) {
  final ws = ref.watch(wsProvider);
  // 用 read 拿 auth 一次：避免 auth 变化重建 provider 导致 _timers 全丢
  final notifier = TypingNotifier();

  final typingSub = ws.typingStream.listen((d) {
    final auth = ref.read(authProvider);
    final eventUserId = d['user_id'] as String?;
    final agentId = d['agent_id'] as String?;
    if (eventUserId != auth.user?.id || agentId == null) return;
    notifier.startTyping(agentId);
  });

  // 收到 agent 的真实消息即清掉对应 typing（无论用户当前在哪个页面）。
  final msgSub = ws.messages
      .where((m) => m.t == 'MESSAGE_CREATE')
      .listen((m) {
    final d = m.d as Map<String, dynamic>?;
    if (d == null) return;
    if (d['sender_type'] != 'agent') return;
    final agentId = d['sender_id'] as String?;
    if (agentId != null) notifier.clearTyping(agentId);
  });

  ref.onDispose(() {
    typingSub.cancel();
    msgSub.cancel();
  });

  return notifier;
});
