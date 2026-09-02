import 'package:app/services/mini_program_bridge.dart';

/// 计算待弹窗的需授权权限列表与最终生效集(纯函数,可测)。
/// declared: manifest 声明;granted: KVS 已授权。
/// pending 仅含未授权的需授权权限(`wanling.chat.*` 涉及用户会话数据,
/// `wanling.nav` 涉及宿主页面跳转;其余如 wanling.api 不弹窗)。
({List<String> pending, Set<String> effective}) resolvePermissionFlow({
  required Set<String> declared,
  required Set<String> granted,
}) {
  final pending = declared
      .where((p) => requiresConsent(p) && !granted.contains(p))
      .toList();
  return (pending: pending, effective: effectivePermissions(declared, granted));
}

/// 授权编排(askUser 注入弹窗,persist 注入落库,均可测)。
/// 拒绝项不进 merged(有效权限集不含 → bridge 持续拒绝);
/// pending 为空不落库(无增量授权)。返回最终有效权限集。
Future<Set<String>> runPermissionFlow({
  required Set<String> declared,
  required Set<String> granted,
  required Future<bool> Function(String perm) askUser,
  required Future<void> Function(Set<String> granted) persist,
}) async {
  final flow = resolvePermissionFlow(declared: declared, granted: granted);
  final merged = Set<String>.of(granted);
  for (final p in flow.pending) {
    if (await askUser(p)) merged.add(p);
  }
  if (flow.pending.isNotEmpty) await persist(merged);
  return effectivePermissions(declared, merged);
}
