import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_provider.dart' show agentListProvider;
import 'auth_provider.dart' show authProvider;
import 'saved_logins_provider.dart' show sharedPrefsProvider;

/// 底部导航 pinned agent tab 有序列表。
///
/// 纯本地持久化状态（SharedPreferences `nav_pins_{ownerId}`）,无 API 三态
/// （模板 flutter-provider 的 loading/error 仅适用 API 型 provider,此处裁剪,
/// 保留 StateNotifier + no-op 守卫约定）。
/// key 按 ownerId 隔离;ownerId 变化（切换账号）时 provider 随 authProvider
/// 重建并重读对应账号列表。
class PinnedNavTabsNotifier extends StateNotifier<List<String>> {
  PinnedNavTabsNotifier({
    required SharedPreferences prefs,
    required String ownerId,
  })  : _prefs = prefs,
        _key = 'nav_pins_$ownerId',
        super(prefs.getStringList('nav_pins_$ownerId') ?? const <String>[]);

  final SharedPreferences _prefs;
  final String _key;

  bool isPinned(String agentId) => state.contains(agentId);

  /// 固定到导航栏：追加队尾（后 pin 的排溢出抽屉末尾）。重复 pin no-op。
  void pin(String agentId) {
    if (state.contains(agentId)) return;
    state = [...state, agentId];
    _persist();
  }

  /// 取消固定。未 pin 的 id no-op。
  void unpin(String agentId) {
    if (!state.contains(agentId)) return;
    state = state.where((id) => id != agentId).toList();
    _persist();
  }

  /// 拖拽排序：把 agentId 移到 pinned 列表的 newIndex。
  /// 底栏可见槽位与 pinned 前缀一一对应,由调用方（HomePage）换算。
  /// 越界/同位/不存在一律 no-op。
  void reorderTo(String agentId, int newIndex) {
    final oldIndex = state.indexOf(agentId);
    if (oldIndex == -1 || newIndex < 0 || newIndex >= state.length) return;
    if (oldIndex == newIndex) return;
    final list = [...state]..removeAt(oldIndex)..insert(newIndex, agentId);
    state = list;
    _persist();
  }

  void _persist() => _prefs.setStringList(_key, state);
}

final pinnedNavTabsProvider =
    StateNotifierProvider<PinnedNavTabsNotifier, List<String>>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  // 登出/切账号的中间态 ownerId 为空串,会读写幽灵 key 'nav_pins_'(空列表)。
  // 这是固定依赖的隐式约定:HomePage 收缩守卫靠该空列表判定「当前 agent 已消失」,
  // 从而回退消息 tab;ownerId 恢复后 provider 随 authProvider 重建读回真实 key。
  final ownerId = ref.watch(authProvider.select((s) => s.user?.id ?? ''));
  return PinnedNavTabsNotifier(prefs: prefs, ownerId: ownerId);
});

/// 有效性派生：pinned ∩ 当前 agent 列表。agent 被删除时自动收缩,
/// 底栏/PageView 以此为唯一事实源。
final effectivePinnedNavTabsProvider = Provider<List<String>>((ref) {
  final pinned = ref.watch(pinnedNavTabsProvider);
  final agents = ref.watch(agentListProvider);
  return [
    for (final id in pinned)
      if (agents.any((a) => a.id == id)) id,
  ];
});
