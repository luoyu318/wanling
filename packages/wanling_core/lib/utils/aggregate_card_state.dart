import '../models/message.dart';
import '../models/msg_type.dart';

/// 判定会话是否存在 generating 状态的聚合卡。
/// 聚合卡生成期间(footer 未出 / state=generating)由卡片自身承载生成状态,
/// 聊天列表底部 busy 气泡应隐藏,避免重复提示。
/// 纯函数供 chat_page._refreshExtraItems 调用,独立可测。
bool hasGeneratingAggregateCard(List<ChatMessage> messages) {
  for (final m in messages) {
    final content = m.content;
    if (content['msg_type'] != MsgType.aggregateCard.value) continue;
    final state = (content['data'] as Map?)?['state'];
    if (state != 'done') return true;
  }
  return false;
}
