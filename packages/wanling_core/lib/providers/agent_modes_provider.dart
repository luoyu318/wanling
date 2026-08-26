// packages/wanling_core/lib/providers/agent_modes_provider.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/agent_mode.dart';
import 'package:wanling_core/models/agent_preset.dart';
import 'package:wanling_core/providers/auth_provider.dart';

/// 某 agent 的模式清单(plugin 上报、server 内存缓存)。
/// family by agentId;autoDispose:无 listener 时释放(离开会话),重进
/// 重拉——清单随 plugin 重连变化,不做长缓存。加载失败/空清单均返
/// 空列表(合法态:无模式概念 plugin 未上报 / server 重启)。
final agentModesProvider =
    FutureProvider.autoDispose.family<List<AgentMode>, String>(
        (ref, agentId) async {
  try {
    return await ref.watch(apiProvider).getAgentModes(agentId);
  } catch (_) {
    return const <AgentMode>[];
  }
});

/// 某 agent 的预设清单(同生命周期语义)。
/// 无预设概念的 plugin 不上报 → 空列表 → APP 隐藏选择步骤。
final agentPresetsProvider =
    FutureProvider.autoDispose.family<List<AgentPreset>, String>(
        (ref, agentId) async {
  try {
    return await ref.watch(apiProvider).getAgentPresets(agentId);
  } catch (_) {
    return const <AgentPreset>[];
  }
});
