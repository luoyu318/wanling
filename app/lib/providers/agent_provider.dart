import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/agent.dart';
import '../models/ws_message.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';
import 'auth_provider.dart';
import 'chat_provider.dart' show wsProvider;

/// 把 agent name 缓存到 SharedPreferences，供 service isolate 通知标题用。
/// 失败不阻塞主流程（仅记日志）：缓存缺失只会导致通知标题降级为 agent_id，
/// 不该让 agent 列表加载/创建/更新失败。
/// 测试环境下若 SharedPreferences 未初始化，getInstance 会抛 MissingPluginException，
/// 这里吞掉避免污染纯单元测试。
Future<void> _cacheAgentName(String id, String name) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agent_name_$id', name);
  } catch (e) {
    debugPrint('[agent] 缓存 name($id) 失败: $e');
  }
}

class AgentListNotifier extends StateNotifier<List<Agent>> {
  final ApiService api;
  final WebSocketService ws;
  StreamSubscription<WSMessage>? _subscription;

  AgentListNotifier(this.api, this.ws) : super([]) {
    load();
    // 订阅 AGENT_ONLINE/AGENT_OFFLINE 实时更新 status。
    // 否则列表上的在线小圆点只是首次拉取时的快照，agent 上下线后不会变。
    _subscription = ws.messages
        .where((m) => m.t == 'AGENT_ONLINE' || m.t == 'AGENT_OFFLINE')
        .listen(_onAgentStatusChange);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _onAgentStatusChange(WSMessage m) {
    final data = m.d as Map<String, dynamic>?;
    if (data == null) return;
    final agentId = data['agent_id'] as String?;
    if (agentId == null) return;

    final newStatus =
        m.t == 'AGENT_ONLINE' ? AgentStatus.online : AgentStatus.offline;

    final idx = state.indexWhere((a) => a.id == agentId);
    // 不在列表（user 还没拉过 / agent 不属于当前用户）：忽略，避免引入不完整对象。
    if (idx == -1) return;
    if (state[idx].status == newStatus) return;

    state = [
      for (final a in state)
        if (a.id == agentId)
          a.copyWith(status: newStatus)
        else a,
    ];
  }

  Future<void> load() async {
    final list = await api.getAgents();
    state = list.map((e) => Agent.fromJson(e)).toList();
    // 缓存 agent name 到 SharedPreferences，供 service isolate 通知标题用
    for (final a in state) {
      await _cacheAgentName(a.id, a.name);
    }
  }

  Future<Agent> create(String name) async {
    final data = await api.createAgent(name);
    final agent = Agent.fromJson(data);
    state = [...state, agent];
    // 缓存 agent name
    await _cacheAgentName(agent.id, agent.name);
    return agent;
  }

  Future<void> delete(String id) async {
    await api.deleteAgent(id);
    state = state.where((a) => a.id != id).toList();
  }

  /// 更新 Agent 资料：本地同步（copyWith）+ 后端持久化。
  /// name/avatarUrl/bio 均可选；null=不动，bio=""=清空。
  Future<void> update(
    String id, {
    String? name,
    String? avatarUrl,
    String? bio,
  }) async {
    await api.updateAgent(id, name: name, avatarUrl: avatarUrl, bio: bio);

    state = [
      for (final a in state)
        if (a.id == id)
          a.copyWith(
            name: name,
            avatarUrl: avatarUrl,
            bio: bio,
            clearBio: bio == '',
          )
        else a,
    ];

    // 若 name 变了，更新通知标题缓存
    if (name != null) {
      await _cacheAgentName(id, name);
    }
  }
}

final agentListProvider = StateNotifierProvider<AgentListNotifier, List<Agent>>((ref) {
  return AgentListNotifier(ref.watch(apiProvider), ref.watch(wsProvider));
});

/// 按 ID 查 agent，仅在该 agent 变化时重建（而不是每帧扫描）。
/// 内部仍线性扫描 agentListProvider，但 family 的语义让 ChatPage 等
/// 多 family listener 不会互相干扰；agent 数量通常 <100，O(n) 完全可接受。
final agentByIdProvider = Provider.family<Agent?, String>((ref, id) {
  final agents = ref.watch(agentListProvider);
  return agents.where((a) => a.id == id).firstOrNull;
});
