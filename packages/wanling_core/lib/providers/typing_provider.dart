import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'chat_provider.dart' show wsProvider;

/// per-convId typing 状态。
///
/// 订阅 ws.typingStream(TYPING_START 事件),收到时把对应 convId 标 typing=true,
/// 同时启动 5 秒兜底 Timer(防 agent 卡死时永远显示 typing)。
///
/// agent 真实消息到达时由 ChatPage 调 clearTyping(convId) 显式清掉。
///
/// 协议层用 conversation_id 路由(对齐 server 新协议),不再依赖 sender_id/agent_id 字段。
class TypingNotifier extends StateNotifier<Map<String, bool>> {
  final Map<String, Timer> _timers = {};

  TypingNotifier() : super({});

  /// 标记 convId 正在输入,5 秒兜底超时。
  void startTyping(String convId) {
    state = {...state, convId: true};
    _timers[convId]?.cancel();
    _timers[convId] = Timer(const Duration(seconds: 5), () {
      _clear(convId);
    });
  }

  /// 显式清掉 typing(agent 真实消息到达时调)。
  void clearTyping(String convId) {
    _clear(convId);
  }

  void _clear(String convId) {
    _timers[convId]?.cancel();
    _timers.remove(convId);
    if (!state.containsKey(convId)) return;
    final next = Map<String, bool>.from(state)..remove(convId);
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

/// typingProvider:暴露 per-convId typing 状态 map。
///
/// 订阅两条流:
/// - ws.typingStream(TYPING_START)→ startTyping:按 d['conversation_id'] 标 typing
/// - ws.messages(MESSAGE_CREATE from agent)→ clearTyping:同 conv_id 收到 agent 真实消息即清掉
///
/// clearTyping 放在全局 provider 而非 ChatPage,是为了「用户离开 ChatPage 后
/// typing 也能被正确清除」——ChatPage 的 _msgSub 会随页面 dispose 失效,
/// 导致 typing 卡在 true(仅靠 5s 兜底 timer 不可靠,与消息流时序不同步时会卡死)。
final typingProvider =
StateNotifierProvider<TypingNotifier, Map<String, bool>>((ref) {
  final ws = ref.watch(wsProvider);
  final notifier = TypingNotifier();

  final typingSub = ws.typingStream.listen((d) {
    final convId = d['conversation_id'] as String?;
    if (convId == null || convId.isEmpty) return;
    notifier.startTyping(convId);
  });

  // 收到 agent 的真实消息即清掉对应 conv 的 typing(无论用户当前在哪个页面)。
  // 例外：聚合卡 silent 建卡（content.silent=true，回合进行中）不视为回复完成，
  // 保留 typing 直到回合结束翻转。非 silent 消息照常清。
  final msgSub = ws.messages.where((m) => m.t == 'MESSAGE_CREATE').listen((m) {
    final d = m.d as Map<String, dynamic>?;
    if (d == null) return;
    if (d['sender_type'] != 'agent') return;
    final convId = d['conversation_id'] as String?;
    if (convId == null || convId.isEmpty) return;
    final content = d['content'];
    if (content is Map && content['silent'] == true) return;
    notifier.clearTyping(convId);
  });

  // 聚合卡回合结束：MESSAGE_UPDATE 翻转 silent=true→false 时清 typing（回复完成）。
  final updSub = ws.messages.where((m) => m.t == 'MESSAGE_UPDATE').listen((m) {
    final d = m.d as Map<String, dynamic>?;
    if (d == null) return;
    final convId = d['conversation_id'] as String?;
    if (convId == null || convId.isEmpty) return;
    final content = d['content'];
    final silent = content is Map ? content['silent'] : null;
    if (silent == false) {
      notifier.clearTyping(convId);
    }
  });

  ref.onDispose(() {
    typingSub.cancel();
    msgSub.cancel();
    updSub.cancel();
  });

  return notifier;
});
