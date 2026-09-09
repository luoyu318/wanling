import 'package:app/models/inbox_entry.dart';

/// 收件箱解析状态（不可变）。
///
/// - entries: entryKey → entry（Dart Map 字面量为 LinkedHashMap，天然保插入序 = 入队序）
/// - aggregateViews: 聚合卡 msgId → elementId → element data（增量 op 合并的工作视图）
class InboxParserState {
  final Map<String, InboxEntry> entries;
  final Map<String, Map<String, Map<String, dynamic>>> aggregateViews;

  const InboxParserState({
    this.entries = const {},
    this.aggregateViews = const {},
  });

  InboxParserState withEntry(InboxEntry e) {
    if (entries.containsKey(e.entryKey)) return this;
    return InboxParserState(
      entries: {...entries, e.entryKey: e},
      aggregateViews: aggregateViews,
    );
  }

  /// 移除某消息的全部 entry（全量 UPDATE 重建前清理）。
  InboxParserState withoutMsg(String msgId) {
    final kept = Map<String, InboxEntry>.from(entries)
      ..removeWhere((_, e) => e.msgId == msgId);
    final views = Map<String, Map<String, Map<String, dynamic>>>.from(
        aggregateViews)
      ..remove(msgId);
    return InboxParserState(entries: kept, aggregateViews: views);
  }

  /// 某消息当前占用的全部 entryKey。
  List<String> entryKeysOfMsg(String msgId) =>
      entries.values.where((e) => e.msgId == msgId).map((e) => e.entryKey).toList();
}

class InboxParseResult {
  final InboxParserState state;
  final List<InboxEntry> added;
  final List<String> removedKeys;
  const InboxParseResult(this.state, this.added, this.removedKeys);
}

/// 空结果常量。
InboxParseResult _noop(InboxParserState s) => InboxParseResult(s, const [], const []);

/// MESSAGE_CREATE 入口：按 msg_type 判定四类 pending 卡。
InboxParseResult ingestCreate(
    InboxParserState s, String msgId, String convId, Map<String, dynamic> content) {
  final mt = content['msg_type'] as String?;
  final data = content['data'];
  switch (mt) {
    case 'permission_card':
    case 'question_card':
      final status = data is Map ? (data['status'] as String? ?? 'pending') : 'pending';
      if (status != 'pending') return _noop(s);
      if (s.entries.containsKey(msgId)) return _noop(s); // 幂等：已在队不重复入队
      final e = InboxEntry(
        entryKey: msgId,
        msgId: msgId,
        convId: convId,
        kind: mt == 'permission_card' ? InboxCardKind.ocPermission : InboxCardKind.ocQuestion,
        data: data is Map ? Map<String, dynamic>.from(data) : const {},
      );
      return InboxParseResult(s.withEntry(e), [e], const []);
    case 'card':
      final state = data is Map ? (data['state'] as String? ?? 'pending') : 'pending';
      if (state != 'pending') return _noop(s);
      if (s.entries.containsKey(msgId)) return _noop(s); // 幂等：已在队不重复入队
      final e = InboxEntry(
        entryKey: msgId,
        msgId: msgId,
        convId: convId,
        kind: InboxCardKind.approvalCard,
        data: data is Map ? Map<String, dynamic>.from(data) : const {},
      );
      return InboxParseResult(s.withEntry(e), [e], const []);
    case 'aggregate_card':
      // 建卡/全量重建：清旧视图后重扫 elements。
      var next = s.withoutMsg(msgId);
      final removed = s.entryKeysOfMsg(msgId);
      final added = <InboxEntry>[];
      if (data is Map) {
        final els = data['elements'];
        if (els is List) {
          for (final el in els) {
            if (el is! Map) continue;
            final r = _ingestAggregateElement(next, msgId, convId, Map<String, dynamic>.from(el));
            next = r.state;
            added.addAll(r.added);
          }
        }
      }
      return InboxParseResult(next, added, removed);
    default:
      return _noop(s);
  }
}

/// MESSAGE_UPDATE 入口：聚合卡增量 op 或全量替换。
InboxParseResult ingestUpdate(
    InboxParserState s, String msgId, String convId, Map<String, dynamic> content) {
  final data = content['data'];
  if (data is Map && content['msg_type'] == 'aggregate_card') {
    switch (data['op'] as String?) {
      case 'append':
        final el = data['element'];
        if (el is! Map) return _noop(s);
        return _ingestAggregateElement(s, msgId, convId, Map<String, dynamic>.from(el));
      case 'update':
        final eid = data['element_id'] as String?;
        final patch = data['data'];
        if (eid == null || patch is! Map) return _noop(s);
        final status = patch['status'] as String? ?? 'pending';
        final key = '$msgId:$eid';
        if (status != 'pending' && s.entries.containsKey(key)) {
          // 终态收敛出队；视图更新防后续重复。
          // 内层视图整层重建：原地写会变异与旧 state 共享的内层 map，破坏不可变契约。
          final views = Map<String, Map<String, Map<String, dynamic>>>.from(s.aggregateViews);
          views[msgId] = {...(views[msgId] ?? const {}), eid: Map<String, dynamic>.from(patch)};
          final entries = Map<String, InboxEntry>.from(s.entries)..remove(key);
          return InboxParseResult(
              InboxParserState(entries: entries, aggregateViews: views), const [], [key]);
        }
        return _noop(s);
      case 'remove':
        final eid = data['element_id'] as String?;
        if (eid == null) return _noop(s);
        final key = '$msgId:$eid';
        if (!s.entries.containsKey(key)) return _noop(s);
        final entries = Map<String, InboxEntry>.from(s.entries)..remove(key);
        return InboxParseResult(
            InboxParserState(entries: entries, aggregateViews: s.aggregateViews),
            const [],
            [key]);
      case null:
        break; // 无 op = 全量替换，走底部收敛
      default:
        return _noop(s); // reorder/set_state/set_silent/set_segment 不影响 pending 判定
    }
  }
  // 全量替换（无 op）：清该 msgId 全部 entry 后按建卡逻辑重新收敛。
  final priorKeys = s.entryKeysOfMsg(msgId);
  final r = ingestCreate(s.withoutMsg(msgId), msgId, convId, content);
  final removed = {...priorKeys.where((k) => !r.added.any((a) => a.entryKey == k))};
  return InboxParseResult(r.state, r.added, removed.toList());
}

/// 单个聚合卡交互元素判定（append / 建卡扫描共用）。
InboxParseResult _ingestAggregateElement(InboxParserState s, String msgId,
    String convId, Map<String, dynamic> element) {
  final type = element['type'] as String?;
  if (type != 'permission_card' && type != 'question_card') return _noop(s);
  final eid = element['element_id'] as String?;
  if (eid == null || eid.isEmpty) return _noop(s);
  final raw = element['data'];
  final elData = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  final status = elData['status'] as String? ?? 'pending';

  // 同步工作视图（无论 pending 与否，视图都要反映最新 data）。
  // 内层视图整层重建：原地写会变异与旧 state 共享的内层 map，破坏不可变契约。
  final views = Map<String, Map<String, Map<String, dynamic>>>.from(s.aggregateViews);
  views[msgId] = {...(views[msgId] ?? const {}), eid: elData};

  final key = '$msgId:$eid';
  if (status != 'pending' || s.entries.containsKey(key)) {
    // 非.pending 或已在队（幂等去重）：只同步视图，不动队列。
    return InboxParseResult(InboxParserState(entries: s.entries, aggregateViews: views), const [], const []);
  }
  final e = InboxEntry(
    entryKey: key,
    msgId: msgId,
    convId: convId,
    elementId: eid,
    kind: InboxCardKind.aggregateElement,
    data: elData,
  );
  return InboxParseResult(
      InboxParserState(entries: s.withEntry(e).entries, aggregateViews: views), [e], const []);
}
