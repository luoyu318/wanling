import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_provider.dart' show agentListProvider;
import 'auth_provider.dart' show authProvider;
import 'saved_logins_provider.dart' show sharedPrefsProvider;

/// 底栏固定 tab 的保留 id(agent id 为 UUID,不会与之冲突)。
const kNavTabMsg = 'msg';
const kNavTabWanling = 'wanling';
const kNavFixedIds = {kNavTabMsg, kNavTabWanling};

/// 底部导航槽位有序序列(含固定项 + pinned agent)。
///
/// 纯本地持久化(SharedPreferences `nav_order_{ownerId}`);首次读取缺失时
/// 从旧 `nav_pins_{ownerId}` 一次性迁移(固定项前置)。序列任意排序,
/// 唯一不变式:固定项各恰好一次且不可移除(见 sanitize/unpin)。
/// key 按 ownerId 隔离;ownerId 变化(切换账号)时 provider 随 authProvider 重建。
class NavOrderNotifier extends StateNotifier<List<String>> {
  NavOrderNotifier({
    required SharedPreferences prefs,
    required String ownerId,
  })  : _prefs = prefs,
        _key = 'nav_order_$ownerId',
        _anonymous = ownerId.isEmpty,
        super(const <String>[]) {
    // _load 只读一次,迁移标记随 record 带出。
    final (initial, migrated) = _load(prefs, ownerId);
    _migratedFromLegacy = migrated;
    // 登出中间态:维持幽灵 key 空列表语义,不 sanitize 不 persist。
    if (_anonymous) return;
    state = initial;
    // 本地持久数据不作信任源:构造时 sanitize,变化或迁移即落盘。
    final clean = _sanitize(state);
    if (_migratedFromLegacy || !listEquals(clean, state)) {
      state = clean;
      _persist();
    }
  }

  final SharedPreferences _prefs;
  final String _key;

  /// 迁移标记:_load 是否从旧 nav_pins 搬运了数据( true 则构造时强制落盘新 key)。
  bool _migratedFromLegacy = false;

  /// 登出/切账号中间态 ownerId 为空串,不 sanitize 不 persist。
  bool _anonymous = false;

  /// 首读:新 key 缺失时从旧 nav_pins 迁移(固定项前置)。
  /// 返回第二元标记是否发生迁移,供构造函数决定强制落盘。
  /// 空 ownerId(登出中间态)沿用幽灵 key 约定:空列表,不迁移。
  static (List<String>, bool) _load(
      SharedPreferences prefs, String ownerId) {
    final current = prefs.getStringList('nav_order_$ownerId');
    if (current != null) return (current, false);
    if (ownerId.isEmpty) return (const <String>[], false);
    final legacy = prefs.getStringList('nav_pins_$ownerId') ?? const <String>[];
    return ([kNavTabMsg, kNavTabWanling, ...legacy], legacy.isNotEmpty);
  }

  /// 不变式修复:去空/去重保序;固定项保证恰好一次(仅缺失才补,补位后固定项相邻)。
  /// **位置不强制**:固定项可在任意位(全槽任意排序的核心语义)。
  static List<String> _sanitize(List<String> raw) {
    final seen = <String>{};
    final out = <String>[];
    var hasMsg = false, hasWanling = false;
    for (final id in raw) {
      if (id.isEmpty || !seen.add(id)) continue;
      if (id == kNavTabMsg) {
        if (hasMsg) continue;
        hasMsg = true;
      } else if (id == kNavTabWanling) {
        if (hasWanling) continue;
        hasWanling = true;
      }
      out.add(id);
    }
    // 补位:wanling 缺失插到 msg 紧前(msg 亦缺时先占最前),msg 缺失补最前。
    if (!hasWanling) {
      final msgIdx = out.indexOf(kNavTabMsg);
      out.insert(msgIdx == -1 ? 0 : msgIdx, kNavTabWanling);
    }
    if (!hasMsg) out.insert(0, kNavTabMsg);
    return out;
  }

  bool isPinned(String agentId) => state.contains(agentId);

  /// 固定到导航栏:追加队尾。重复 pin no-op。
  void pin(String agentId) {
    if (state.contains(agentId)) return;
    state = [...state, agentId];
    _persist();
  }

  /// 取消固定。固定项拒绝;未 pin 的 id no-op。
  void unpin(String id) {
    if (kNavFixedIds.contains(id)) return;
    if (!state.contains(id)) return;
    state = state.where((e) => e != id).toList();
    _persist();
  }

  /// 排序(move 语义):把 id 移到 newIndex,其余项顺移。任意项(含固定项)
  /// 均可移动;越界/同位/不存在 no-op。move 永不增删项,固定项不可移除不变式天然保持。
  void reorder(String id, int newIndex) {
    final oldIndex = state.indexOf(id);
    if (oldIndex == -1 || newIndex < 0 || newIndex >= state.length) return;
    if (oldIndex == newIndex) return;
    final list = [...state]..removeAt(oldIndex)..insert(newIndex, id);
    state = list;
    _persist();
  }

  void _persist() => _prefs.setStringList(_key, state);
}

final navOrderProvider =
    StateNotifierProvider<NavOrderNotifier, List<String>>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  // 登出/切账号的中间态 ownerId 为空串,会读写幽灵 key 'nav_order_'(空列表)。
  // 这是固定依赖的隐式约定:HomePage 收缩守卫靠该空序列判定「当前 tab 已消失」,
  // 从而回退页 0;ownerId 恢复后 provider 随 authProvider 重建读回真实 key。
  final ownerId = ref.watch(authProvider.select((s) => s.user?.id ?? ''));
  return NavOrderNotifier(prefs: prefs, ownerId: ownerId);
});

/// 有效性派生:序列 ∩ 当前 agent 列表(固定项恒保留)。agent 被删除时自动收缩,
/// 底栏/PageView/编辑页以此为唯一事实源。
final effectiveNavOrderProvider = Provider<List<String>>((ref) {
  final order = ref.watch(navOrderProvider);
  final agents = ref.watch(agentListProvider);
  return [
    for (final id in order)
      if (kNavFixedIds.contains(id) || agents.any((a) => a.id == id)) id,
  ];
});
