// packages/wanling_core/lib/providers/agent_types_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/agent_type_info.dart';
import 'package:wanling_core/providers/auth_provider.dart';

/// agent type 注册表(server 统一下发)。徽标查表与类型下拉的数据源。
/// 全局静态数据:非 autoDispose,登录周期内缓存;失败返空列表
/// (调用方 fallback 本地兜底:label=type 原文 + 默认配色)。
final agentTypesProvider = FutureProvider<List<AgentTypeInfo>>((ref) async {
  try {
    return await ref.watch(apiProvider).getAgentTypes();
  } catch (_) {
    return const <AgentTypeInfo>[];
  }
});

/// 按 type 查是否多 session 拓扑(server 注册表优先,本地 fallback 兜底,
/// 未注册返回 false)。供只有 type 字符串(拿不到 Agent/AgentSummary 的
/// server 注入值)的场景判断,如 chat AppBar 徽标显隐。
bool multiSessionOfType(WidgetRef ref, String type) {
  if (type.isEmpty) return false;
  final server = ref.read(agentTypesProvider).valueOrNull;
  if (server != null) {
    for (final t in server) {
      if (t.type == type) return t.multiSession;
    }
  }
  for (final t in AgentTypeInfo.fallbackTypes) {
    if (t.type == type) return t.multiSession;
  }
  return false;
}
