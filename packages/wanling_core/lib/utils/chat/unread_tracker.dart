import '../../models/message.dart';

/// 计算当前视口内新进入的未读消息 id 列表。
///
/// 提取为顶层 pure function 便于 unit test 直接驱动（避免依赖 ScrollController / viewport）。
/// 由聊天页滚动监听调用（视口变化时驱动本函数,返回的 id 列表用于触发本地 unreadCount 递减
/// + debounce 后批量 markMessagesRead 同步服务端）。
///
/// 三个过滤维度：
///   1. msg.isRead == false（server 端 user 自发落地 TRUE，故 user 消息自动跳过）
///   2. 不在 seenUnreadMsgIds 内（已计入过的不再重复 decrement）
///   3. isInViewport(msg.id) == true（由调用方注入 viewport 检查函数）
List<String> computeNewlySeenUnread({
  required List<ChatMessage> messages,
  required int firstUnreadIdx,
  required Set<String> seenUnreadMsgIds,
  required bool Function(String messageId) isInViewport,
}) {
  final newlySeen = <String>[];
  for (var i = 0; i <= firstUnreadIdx; i++) {
    final msg = messages[i];
    // 过滤口径：只看 isRead 单一字段。
    // server 端 createMessage 对 user 发的消息落地 is_read=TRUE（自己发的不计未读），
    // 故 client 不再需要 senderType 兜底。参与者模型重构后，client 这层逻辑天然兼容
    // （只看字段不看角色）。
    if (msg.isRead) continue;
    if (seenUnreadMsgIds.contains(msg.id)) continue;
    if (isInViewport(msg.id)) newlySeen.add(msg.id);
  }
  return newlySeen;
}
