import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_provider.dart' show agentListProvider;
import 'auth_provider.dart' show authProvider;
import 'conversation_provider.dart' show conversationProvider;
import 'saved_logins_provider.dart' show sharedPrefsProvider;

/// 底栏固定 tab 的保留 id(agent id 为 UUID,不会与之冲突)。
const kNavTabMsg = 'msg';
const kNavTabWanling = 'wanling';
const kNavFixedIds = {kNavTabMsg, kNavTabWanling};

/// 会话槽前缀:底栏序列中会话槽存 'conv:<convId>'(agent 为 UUID,不会冲突)。
const kNavConvPrefix = 'conv:';

/// 该序列元素是否为会话槽。
bool isConvNavId(String id) => id.startsWith(kNavConvPrefix);

/// 'conv:<convId>' → convId;非会话槽返回 null。
String? navConvIdOf(String id) =>
    isConvNavId(id) ? id.substring(kNavConvPrefix.length) : null;

/// convId → 会话槽序列元素。
String navConvRef(String convId) => '$kNavConvPrefix$convId';

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

/// 有效性派生:序列 ∩ 当前 agent 列表与会话列表(固定项恒保留)。agent 被删除、
/// 会话被删除/隐藏(移出 conversationProvider state)时自动收缩,
/// 底栏/PageView/编辑页以此为唯一事实源。
final effectiveNavOrderProvider = Provider<List<String>>((ref) {
  final order = ref.watch(navOrderProvider);
  final agents = ref.watch(agentListProvider);
  final convs = ref.watch(conversationProvider);
  bool alive(String id) {
    if (kNavFixedIds.contains(id)) return true;
    final convId = navConvIdOf(id);
    if (convId != null) return convs.any((c) => c.id == convId);
    return agents.any((a) => a.id == id);
  }

  return [for (final id in order) if (alive(id)) id];
});

/// 底栏可见槽数(用户在编辑页拖项进/出「更多」决定;未显式设置时自动推导)。
/// SP `nav_visible_{ownerId}`,值 -1 表示未显式设置(自动模式)。
class NavVisibleCountNotifier extends StateNotifier<int> {
  NavVisibleCountNotifier({
    required SharedPreferences prefs,
    required String ownerId,
  })  : _prefs = prefs,
        _key = 'nav_visible_$ownerId',
        _anonymous = ownerId.isEmpty,
        super(ownerId.isEmpty ? autoVisibleCount : (prefs.getInt('nav_visible_$ownerId') ?? autoVisibleCount));

  final SharedPreferences _prefs;
  final String _key;

  /// 登出/切账号中间态不读不写。
  final bool _anonymous;

  void set(int n) {
    if (_anonymous) return;
    final v = n.clamp(1, 4);
    if (v == state) return;
    state = v;
    _prefs.setInt(_key, v);
  }

  void _persist() => _prefs.setInt(_key, state);
}

final navVisibleCountProvider =
    StateNotifierProvider<NavVisibleCountNotifier, int>((ref) {
  final prefs = ref.watch(sharedPrefsProvider);
  final ownerId = ref.watch(authProvider.select((s) => s.user?.id ?? ''));
  return NavVisibleCountNotifier(prefs: prefs, ownerId: ownerId);
});

/// 未显式设置时的自动可见数:总项 ≤4 全可见,>4 可见 4。
const int autoVisibleCount = -1;

/// 可见槽数推导:显式存储优先(clamp 1..4 且 ≤总项),未设置时按自动规则。
/// totalItems = 有效导航序列总长;返回值恒 ≥1(底栏最少保留一个导航元素)。
int resolveVisibleCount(int stored, int totalItems) {
  if (totalItems <= 0) return 1;
  if (stored <= autoVisibleCount) return totalItems <= 4 ? totalItems : 4;
  return stored.clamp(1, 4).clamp(1, totalItems);
}
