import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:app/models/inbox_entry.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/services/websocket_service.dart';
import 'package:app/services/inbox_parser.dart';

/// 收件箱弹窗状态机。
class ApprovalInboxState {
  /// 待决策队列（入队序）。头条 = 当前应展示的卡。
  final List<InboxEntry> queue;

  /// 经 300ms 防抖后的「允许弹窗」信号。
  final bool exposing;

  /// 「暂不处理」后暂停自动弹；新卡入队重置。
  final bool suppressed;

  /// 已提交决策、等 MESSAGE_UPDATE 收敛的 key（防同卡重弹）。
  final Set<String> awaitingKeys;

  const ApprovalInboxState({
    this.queue = const [],
    this.exposing = false,
    this.suppressed = false,
    this.awaitingKeys = const {},
  });

  ApprovalInboxState copyWith({
    List<InboxEntry>? queue,
    bool? exposing,
    bool? suppressed,
    Set<String>? awaitingKeys,
  }) =>
      ApprovalInboxState(
        queue: queue ?? this.queue,
        exposing: exposing ?? this.exposing,
        suppressed: suppressed ?? this.suppressed,
        awaitingKeys: awaitingKeys ?? this.awaitingKeys,
      );
}

/// 全局审批收件箱：订阅 WS 流驱动入队/收敛，不写任何消息状态。
class ApprovalInboxController extends StateNotifier<ApprovalInboxState> {
  final WebSocketService _ws;
  StreamSubscription<WSMessage>? _createSub;
  StreamSubscription<WSMessage>? _updateSub;
  Timer? _exposeDebounce;
  InboxParserState _parser = const InboxParserState();

  ApprovalInboxController(this._ws) : super(const ApprovalInboxState()) {
    _createSub = _ws.messages.listen(_onMessageCreate);
    _updateSub = _ws.messageUpdates.listen(_onMessageUpdate);
  }

  void _onMessageCreate(WSMessage m) {
    final d = m.d;
    if (d is! Map) return;
    final msgId = d['id'] as String?;
    final convId = d['conversation_id'] as String?;
    final content = d['content'];
    if (msgId == null || convId == null || content is! Map) return;
    final r = ingestCreate(
        _parser, msgId, convId, Map<String, dynamic>.from(content));
    _parser = r.state;
    _apply(r.added, r.removedKeys);
  }

  void _onMessageUpdate(WSMessage m) {
    final d = m.d;
    if (d is! Map) return;
    final msgId = d['message_id'] as String?;
    final convId = d['conversation_id'] as String?;
    final content = d['content'];
    if (msgId == null || convId == null || content is! Map) return;
    final r = ingestUpdate(
        _parser, msgId, convId, Map<String, dynamic>.from(content));
    _parser = r.state;
    _apply(r.added, r.removedKeys);
  }

  void _apply(List<InboxEntry> added, List<String> removed) {
    if (added.isEmpty && removed.isEmpty) return;
    final removedSet = removed.toSet();
    var queue = state.queue
        .where((e) =>
            !removedSet.contains(e.entryKey) && !removedSet.contains(e.msgId))
        .toList();
    for (final e in added) {
      if (!queue.any((q) => q.entryKey == e.entryKey)) queue = [...queue, e];
    }
    final awaiting = state.awaitingKeys.difference(removedSet);
    if (queue.isEmpty) {
      _exposeDebounce?.cancel();
      _exposeDebounce = null;
      state = state.copyWith(
          queue: queue, exposing: false, awaitingKeys: awaiting);
      return;
    }
    final hasNew = added.isNotEmpty;
    final suppressed = hasNew ? false : state.suppressed;
    if (hasNew && state.exposing == false && suppressed == false) {
      _exposeDebounce?.cancel();
      _exposeDebounce = Timer(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        state = state.copyWith(exposing: true);
      });
    }
    state = state.copyWith(
        queue: queue, suppressed: suppressed, awaitingKeys: awaiting);
  }

  /// 「暂不处理」/返回键：收起且暂停自动弹（队列保留）。
  void dismissCurrent() {
    _exposeDebounce?.cancel();
    _exposeDebounce = null;
    state = state.copyWith(suppressed: true, exposing: false);
  }

  /// 决策提交成功后标记，防 MESSAGE_UPDATE 回流前同卡重弹。
  void markAwaitingConfirm(String entryKey) {
    state = state.copyWith(awaitingKeys: {...state.awaitingKeys, entryKey});
  }

  @override
  void dispose() {
    _createSub?.cancel();
    _updateSub?.cancel();
    _exposeDebounce?.cancel();
    super.dispose();
  }
}

/// 全局单例（非 autoDispose：常驻跟随 WS 生命周期）。
final approvalInboxProvider =
    StateNotifierProvider<ApprovalInboxController, ApprovalInboxState>((ref) {
  return ApprovalInboxController(ref.watch(wsProvider));
});
