import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/session_diff.dart';
import '../services/api_service.dart';
import 'auth_provider.dart' show apiProvider;

typedef SessionDiffKey = ({String agentId, String convId});

class SessionDiffNotifier extends StateNotifier<AsyncValue<List<SessionDiffFile>>> {
  final ApiService _api;
  final String agentId;
  final String convId;

  SessionDiffNotifier(this._api, {required this.agentId, required this.convId})
      : super(const AsyncValue.loading());

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      state = AsyncValue.data(await _fetch());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> refresh() async {
    try {
      state = AsyncValue.data(await _fetch());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<List<SessionDiffFile>> _fetch() async {
    final result = await _api.rpc(
      agentId,
      'session.diff',
      {'wanling_conv_id': convId},
      timeoutMs: 10000,
    );
    final list = (result['files'] as List?) ?? const [];
    return list
        .map((e) => SessionDiffFile.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final sessionDiffProvider = StateNotifierProvider.autoDispose.family<
    SessionDiffNotifier, AsyncValue<List<SessionDiffFile>>, SessionDiffKey>(
  (ref, key) => SessionDiffNotifier(
    ref.watch(apiProvider),
    agentId: key.agentId,
    convId: key.convId,
  )..load(),
);
