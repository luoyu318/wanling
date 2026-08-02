import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'models/agent.dart';
import 'providers/auth_provider.dart' show apiProvider;
import 'utils/snackbar.dart';

/// 拼接 chat 路由路径：convId 走 path 参数，agentId 走 query（可空）。
///
/// user-user DM 会话不传 agentId（路由层会解析成 null）。
String chatRoute(String convId, [String? agentId]) {
  if (agentId == null || agentId.isEmpty) return '/chat/$convId';
  return '/chat/$convId?agentId=$agentId';
}

/// 拼接多 session 开发型 agent(opencode 类)的二级列表页路由。
///
/// 入口:一级消息列表点多 session agent(满足 AgentCategory.supportsMultiSession)行。
/// agentId 走 path 参数,二级页据此调 getAgentSessions 拉取 session 群列表。
String sessionsRoute(String agentId) => '/agent/$agentId/sessions';

/// findOrCreate 会话后跳转 chat 页（统一错误处理）。
/// 调用方需在调用前已确保 conversation 存在的场景（如 IM 列表已有 conv），
/// 请直接用 [chatRoute] 拼路径 push，不要走此 helper。
Future<void> startChatAndPush(
  BuildContext context,
  WidgetRef ref,
  Agent agent,
) async {
  try {
    final conv = await ref.read(apiProvider).findOrCreateConversation(agent.id);
    if (!context.mounted) return;
    context.push(chatRoute(conv.id, agent.id));
  } catch (e) {
    if (!context.mounted) return;
    showAppSnackBar(context, '创建会话失败: $e', type: SnackBarType.error);
  }
}

/// 跳转到文件浏览页（会话内 + PlusPanel 入口）。
///
/// 入口：agent_session 聊天页 PlusPanel 第 5 格「浏览」。
void openFileBrowser(
  BuildContext context, {
  required String agentId,
  required String convId,
  String? cwd,
}) {
  final cwdQuery = cwd == null ? '' : '?cwd=${Uri.encodeComponent(cwd)}';
  context.push('/file-browser/$agentId/$convId$cwdQuery');
}
