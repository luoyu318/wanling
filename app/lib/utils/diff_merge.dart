/// 列表级 diff-merge: 三 list provider 共用。
///
/// 不直接覆盖, 而是按 [mergeItem] 字段级合并, 本地多余项走 [keepLocal] 决策。
///
/// 算法:
/// 1. fresh 中有的: 走 [mergeItem] 字段级合并(无 local 直接用 fresh)
/// 2. 本地有 fresh 没有的: 走 [keepLocal] 决策(true=保留, false=删)
///
/// 三 list 的 keepLocal 当前都返 false(server 是 source of truth, 本地多余即删),
/// 保留参数为未来 client-only 数据(会话草稿 / 收藏)扩展铺路。
List<T> diffMerge<T>({
  required List<T> localList,
  required List<T> freshList,
  required String Function(T) idOf,
  required T Function(T local, T fresh) mergeItem,
  required bool Function(T local) keepLocal,
}) {
  final freshIds = <String>{for (final f in freshList) idOf(f)};
  final localById = <String, T>{for (final l in localList) idOf(l): l};

  final merged = <T>[];
  // 1. fresh 中有的: 走字段级 merge
  // 防御性去重:freshList 有重复 id 时只保留首次(当前调用方 server 不会返重复,
  // 但 fail-fast 原则下不让 merged 长出重复项)。
  final seenFresh = <String>{};
  for (final f in freshList) {
    final id = idOf(f);
    if (!seenFresh.add(id)) continue; // 重复 id 跳过
    final local = localById[id];
    merged.add(local == null ? f : mergeItem(local, f));
  }
  // 2. 本地有 fresh 没有的: keepLocal 决策
  // 同样去重,且用 freshSeen 过滤掉已 merge 的 id。
  final seenLocal = <String>{};
  for (final l in localList) {
    final id = idOf(l);
    if (!seenLocal.add(id)) continue; // 重复 id 跳过
    if (!freshIds.contains(id) && keepLocal(l)) {
      merged.add(l);
    }
  }
  return merged;
}
