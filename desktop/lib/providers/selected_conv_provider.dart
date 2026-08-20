import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前选中的会话 id(桌面双栏布局左列选中项)。
/// null 表示未选中,右侧聊天区显示占位。聊天页(Task 5)消费。
final selectedConvProvider = StateProvider<String?>((ref) => null);

/// 选中会话的 agentId 兜底来源。
///
/// agent_session 会话(opencode session)不在 conversationProvider 内,
/// MessagesPage 按 convId 反查 agent 查不到;万灵页二级列表跳转时写入
/// 此 provider,MessagesPage 查不到时用它兜底(slash 面板等依赖 agentId)。
/// 普通会话反查优先,切回普通会话不受残留值影响。
final selectedAgentIdProvider = StateProvider<String?>((ref) => null);
