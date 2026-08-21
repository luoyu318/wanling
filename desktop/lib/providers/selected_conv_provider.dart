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

/// 万灵 tab 独立选中会话 id(与消息 tab 的 selectedConvProvider 隔离)。
///
/// 背景:双 tab 共用一个 provider 时,消息页聊着天切到万灵 tab,右侧
/// 聊天卡残留消息页的会话内容(tab 上下文污染)。拆开后各 tab 选中态
/// 独立:消息页回切恢复原会话,万灵页右侧默认空态,仅在本 tab 内
/// (二级 session 列表/详情页「发消息」CTA)打开会话时显示。
final selectedWanlingConvProvider = StateProvider<String?>((ref) => null);

/// 万灵 tab 选中会话的 agentId 兜底(语义同 selectedAgentIdProvider)。
final selectedWanlingAgentIdProvider = StateProvider<String?>((ref) => null);
