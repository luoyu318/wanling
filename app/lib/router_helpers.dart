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

/// findOrCreate 会话后跳转 chat 页（统一错误处理）。
/// 调用方需在调用前已确保 conversation 存在的场景（如 IM 列表已有 conv），
/// 请直接用 [chatRoute] 拼路径 push，不要走此 helper。
Future<void> startChatAndPush(
  BuildContext context,
  WidgetRef ref,
  Agent agent,
) async {
  try {
    final data = await ref.read(apiProvider).findOrCreateConversation(agent.id);
    if (!context.mounted) return;
    final convId = data['id'] as String;
    context.push(chatRoute(convId, agent.id));
  } catch (e) {
    if (!context.mounted) return;
    showAppSnackBar(context, '创建会话失败: $e', type: SnackBarType.error);
  }
}
