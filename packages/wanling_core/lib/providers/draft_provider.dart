import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/local_message_store_abstract.dart';
import '../services/noop_local_message_store.dart';
import 'local_message_store_provider.dart' show localMessageStoreProvider;

/// 会话输入框草稿。state = 草稿文本(初始 '')。
///
/// **非 autoDispose**(草稿要求跨页面生命周期存活,与 chatProvider 的
/// autoDispose 语义刻意相反)。family key 与 conv_meta 同构,按账号+会话隔离。
///
/// 写入策略:setText 更新内存 + [debounce] 防抖落库;空文本立即删库;
/// dispose 时 pending 文本兜底 fire-and-forget 落库。
/// 草稿是增强功能,落库失败 debugPrint 降级,绝不阻塞聊天主流程。
class DraftNotifier extends StateNotifier<String> {
  DraftNotifier(
    this._store,
    this._ownerId,
    this._convId, {
    this.debounce = const Duration(milliseconds: 500),
  }) : super('') {
    _load();
  }

  final LocalMessageStore _store;
  final String _ownerId;
  final String _convId;
  final Duration debounce;

  Timer? _timer;
  /// 已 setState 但尚未落库的文本(null=无 pending)。dispose flush 用。
  String? _pendingWrite;

  Future<void> _load() async {
    try {
      final saved = await _store.getDraft(_ownerId, _convId);
      // state 非空说明用户已先输入(加载竞态),不覆盖
      if (saved != null && saved.isNotEmpty && state.isEmpty) {
        state = saved;
      }
    } catch (e) {
      debugPrint('[draft] load(${_convId}) fail: $e');
    }
  }

  /// 用户输入回调。空文本 = 用户删光,立即清库(防抖后删会有短暂复活窗口)。
  void setText(String text) {
    state = text;
    _timer?.cancel();
    if (text.isEmpty) {
      _pendingWrite = null;
      _store
          .deleteDraft(_ownerId, _convId)
          .catchError((e) => debugPrint('[draft] delete fail: $e'));
      return;
    }
    _pendingWrite = text;
    _timer = Timer(debounce, () => _save(text));
  }

  Future<void> _save(String text) async {
    try {
      await _store.putDraft(_ownerId, _convId, text);
      if (_pendingWrite == text) _pendingWrite = null;
    } catch (e) {
      debugPrint('[draft] save(${_convId}) fail: $e');
    }
  }

  /// 点发送/外部清除:取消防抖 + 清内存 + 删库。
  Future<void> clear() async {
    _timer?.cancel();
    _pendingWrite = null;
    state = '';
    try {
      await _store.deleteDraft(_ownerId, _convId);
    } catch (e) {
      debugPrint('[draft] clear(${_convId}) fail: $e');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    final pending = _pendingWrite;
    if (pending != null) {
      // dispose 内不能 await,fire-and-forget 兜底
      _store
          .putDraft(_ownerId, _convId, pending)
          .catchError((e) => debugPrint('[draft] flush fail: $e'));
    }
    super.dispose();
  }

  /// StateNotifier.dispose 是 protected,测试经此触发 dispose flush。
  @visibleForTesting
  void disposeTest() => dispose();
}

/// 会话草稿 provider。store 未就绪时 Noop 占位(纯内存降级,与
/// conversationProvider 同款模式)。
final draftProvider = StateNotifierProvider.family<DraftNotifier, String,
    ({String ownerId, String convId})>((ref, key) {
  final store = ref.watch(
      localMessageStoreProvider.select((async) => async.valueOrNull));
  return DraftNotifier(
    store ?? NoopLocalMessageStore(),
    key.ownerId,
    key.convId,
  );
});
