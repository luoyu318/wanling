import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/local_message_store_abstract.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_core/utils/diff_merge.dart';
import 'auth_provider.dart';
import 'chat_provider.dart' show wsProvider;
import 'local_message_store_provider.dart' show localMessageStoreProvider;

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
  /// F5: 本地缓存 store。cache-first 加载 + 关键事件 fire-and-forget 落库。
  /// store 加载中 / 失败时由 Provider 注入 NoopLocalMessageStore 占位,
  /// 此时 provider 退化成纯 API 模式(向后兼容)。
  final LocalMessageStore _store;
  /// F5: 当前 user.id,用作 store 的 owner key。
  final String ownerId;
  StreamSubscription<WSMessage>? _subscription;

  AgentListNotifier(
    this.api,
    this.ws, {
    required LocalMessageStore store,
    required this.ownerId,
    bool autoload = true,
  })  : _store = store,
        super([]) {
    // 构造即拉取:切换账号时 apiProvider/wsProvider 重建会连带重建本 notifier,
    // 新 server 的 agent 列表需要重新拉。autoload=false 仅供单元测试使用,
    // 跳过 load 避免触发未 stub 的 getAgents。
    if (autoload) load();
    // 订阅 AGENT_ONLINE/AGENT_OFFLINE 实时更新 status。
    // 否则列表上的在线小圆点只是首次拉取时的快照,agent 上下线后不会变。
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
    // F5 注: AGENT_ONLINE/OFFLINE 是瞬时状态, 不落库, 下次 load 自然刷新
  }

  /// F5: cache-first + diff-merge 加载。
  ///
  /// 流程:
  /// 1. await store.getAgents(uid) 立即返回 cached → state=cached(仅 state 为空时)
  /// 2. 后台 api.getAgents() → diff-merge(status 字段保留本地) → state=merged
  /// 3. fire-and-forget 写库
  /// 4. 失败静默(state 已是 cached)
  Future<void> load() async {
    List<Agent> cached;
    try {
      cached = await _store.getAgents(ownerId);
    } catch (e) {
      debugPrint('[agent] store.getAgents fail: $e');
      cached = [];
    }
    // 切换账号时 apiProvider/wsProvider 重建会 dispose 本 notifier,
    // 但构造函数里 fire-and-forget 的 load() 可能仍在 await 中。
    // dispose 后再赋值 state 会抛 Bad state;在第一个 await 后守卫。
    if (!mounted) return;
    // cache-first 只在 state 为空(首次加载 / 切换账号 provider 重建)时覆盖。
    // state 已有数据时(下拉刷新),cached 可能因 AGENT_ONLINE/OFFLINE 不落库
    // 而携带陈旧 status,覆盖会让 UI 闪现 / 错误显示离线(agent 断线重连场景,
    // WS 推的 online 被覆盖成 cached 落库时的 offline)。
    // 与 conversation_provider.dart 一致。
    if (cached.isNotEmpty && state.isEmpty) state = cached;

    try {
      final fresh = await api.getAgents();
      if (!mounted) return;

      // 空列表保护: server 异常返空时不覆盖本地
      if (fresh.isEmpty && cached.isNotEmpty) {
        for (final a in state) {
          await _cacheAgentName(a.id, a.name);
        }
        return;
      }

      // Agent 无 client-only 字段, 全字段用 fresh 覆盖。
      // status 由 server presence.IsOnline 实时算(presence key 心跳续期 60s TTL),
      // 比 cached 老值(state 来自 store 落库, 可能滞后很久)和 WS 推过的瞬时值更可靠。
      // 之前 mergeItem 保留 local.status 会导致 cached 老 status 卡死, 退出重登也不更新。
      final merged = diffMerge(
        localList: state,
        freshList: fresh,
        idOf: (a) => a.id,
        mergeItem: (local, f) => f,
        keepLocal: (_) => false,
      );
      state = merged;

      // fire-and-forget 落库
      _store.putAgents(ownerId, merged).catchError(
        (e) => debugPrint('[agent] store.putAgents fail: $e'),
      );

      // 缓存 agent name 到 SharedPreferences, 供 service isolate 通知标题用
      for (final a in state) {
        await _cacheAgentName(a.id, a.name);
      }
    } catch (e) {
      // REST 失败静默: state 已是 cached
      debugPrint('[agent] api.getAgents fail: $e');
    }
  }

  Future<Agent> create(String name, {String type = ''}) async {
    final agent = await api.createAgent(name, type: type);
    state = [...state, agent];
    await _cacheAgentName(agent.id, agent.name);
    // F5: fire-and-forget 落库新 agent
    _store.putAgent(ownerId, agent).catchError(
      (e) => debugPrint('[agent] store.putAgent(create) fail: $e'),
    );
    return agent;
  }

  Future<void> delete(String id) async {
    await api.deleteAgent(id);
    state = state.where((a) => a.id != id).toList();
    // F5: 删除后整个 list 重新落库(简单可靠, 不依赖 delete row)
    _store.putAgents(ownerId, state).catchError(
      (e) => debugPrint('[agent] store.putAgents(delete) fail: $e'),
    );
  }

  /// 重置 agent 密钥,返回新密钥(仅此一次可见)。
  /// 密钥由 server 保管不下发,List 拉来的 agent.secretKey 永远是 null,
  /// 所以这里不更新本地 state(无法写回真实值)。
  /// 调用方(UI)负责一次性展示新密钥供用户抄走。
  Future<String> rotateSecretKey(String id) async {
    return api.rotateAgentSecret(id);
  }

  /// 更新 Agent 资料:本地同步(copyWith) + 后端持久化。
  /// name/avatarUrl/bio 均可选;null=不动, bio=""=清空。
  Future<void> update(
    String id, {
    String? name,
    String? avatarUrl,
    String? bio,
    String? type,
  }) async {
    await api.updateAgent(id, name: name, avatarUrl: avatarUrl, bio: bio, type: type);

    state = [
      for (final a in state)
        if (a.id == id)
          a.copyWith(
            name: name,
            avatarUrl: avatarUrl,
            bio: bio,
            clearBio: bio == '',
            type: type,
          )
        else a,
    ];

    // F5: fire-and-forget 落库更新后的 agent
    final updated = state.where((a) => a.id == id).firstOrNull;
    if (updated != null) {
      _store.putAgent(ownerId, updated).catchError(
        (e) => debugPrint('[agent] store.putAgent(update) fail: $e'),
      );
    }

    // 若 name 变了, 更新通知标题缓存
    if (name != null) {
      await _cacheAgentName(id, name);
    }
  }
}

final agentListProvider = StateNotifierProvider<AgentListNotifier, List<Agent>>((ref) {
  // F5: 从 FutureProvider 取 store, 加载中或失败时用 NoopLocalMessageStore 降级
  final store = ref.watch(localMessageStoreProvider.select((async) => async.valueOrNull));
  final ownerId = ref.watch(authProvider.select((s) => s.user?.id ?? ''));
  return AgentListNotifier(
    ref.watch(apiProvider),
    ref.watch(wsProvider),
    store: store ?? NoopLocalMessageStore(),
    ownerId: ownerId,
  );
});

/// 按 ID 查 agent，仅在该 agent 变化时重建（而不是每帧扫描）。
/// 内部仍线性扫描 agentListProvider，但 family 的语义让 ChatPage 等
/// 多 family listener 不会互相干扰；agent 数量通常 <100，O(n) 完全可接受。
final agentByIdProvider = Provider.family<Agent?, String>((ref, id) {
  final agents = ref.watch(agentListProvider);
  return agents.where((a) => a.id == id).firstOrNull;
});
