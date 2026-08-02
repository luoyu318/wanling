import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'chat_provider.dart' show wsProvider;
import 'typing_provider.dart';

enum AgentStatusType { busy, retry }

class AgentStatus {
  final AgentStatusType type;
  final int? attempt;
  final String? message;

  const AgentStatus({
    required this.type,
    this.attempt,
    this.message,
  });
}

class AgentStatusNotifier extends StateNotifier<Map<String, AgentStatus>> {
  final Map<String, Timer> _fallbackTimers = {};

  AgentStatusNotifier() : super({});

  void setBusy(String convId) {
    state = {...state, convId: const AgentStatus(type: AgentStatusType.busy)};
    _startFallbackTimer(convId);
  }

  void setRetry(String convId, int attempt, String message) {
    state = {
      ...state,
      convId: AgentStatus(type: AgentStatusType.retry, attempt: attempt, message: message),
    };
    _startFallbackTimer(convId);
  }

  void clear(String convId) {
    _fallbackTimers[convId]?.cancel();
    _fallbackTimers.remove(convId);
    if (!state.containsKey(convId)) return;
    final next = Map<String, AgentStatus>.from(state)..remove(convId);
    state = next;
  }

  void _startFallbackTimer(String convId) {
    _fallbackTimers[convId]?.cancel();
    _fallbackTimers[convId] = Timer(const Duration(seconds: 30), () {
      clear(convId);
    });
  }

  @override
  void dispose() {
    for (final t in _fallbackTimers.values) {
      t.cancel();
    }
    super.dispose();
  }
}

final agentStatusProvider =
    StateNotifierProvider<AgentStatusNotifier, Map<String, AgentStatus>>((ref) {
  final ws = ref.watch(wsProvider);
  final notifier = AgentStatusNotifier();

  final sub = ws.sessionStatusStream.listen((d) {
    final convId = d['conversation_id'] as String?;
    if (convId == null || convId.isEmpty) return;
    final status = d['status'] as String?;
    switch (status) {
      case 'busy':
        notifier.setBusy(convId);
        break;
      case 'retry':
        final attempt = (d['attempt'] as num?)?.toInt() ?? 1;
        final message = d['message'] as String? ?? '';
        notifier.setRetry(convId, attempt, message);
        break;
      case 'idle':
        notifier.clear(convId);
        ref.read(typingProvider.notifier).clearTyping(convId);
        break;
    }
  });

  ref.onDispose(() => sub.cancel());
  return notifier;
});
