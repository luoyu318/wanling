import 'package:wanling_core/models/agent.dart' as model;
import 'package:wanling_core/models/conversation.dart' as model;
import 'package:wanling_core/models/friendship.dart' as model;
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/user_summary.dart';

/// 本地消息持久化抽象层。
///
/// 业务侧依赖此 abstract,生产用 DriftLocalMessageStore,
/// 测试用 FakeLocalMessageStore。DB 失败由实现内部 catch + log,
/// 调用方拿到的永远是安全默认值(空列表 / 0 / null)。
abstract class LocalMessageStore {
  // === 生命周期 ===
  Future<void> close();

  // === 消息写入 ===
  Future<void> putMessage(ChatMessage msg);
  Future<void> putMessages(Iterable<ChatMessage> msgs);
  Future<void> updateContent(String msgId, Map<String, dynamic> content);
  Future<void> markRecalled(String msgId, {String recalledByName});
  Future<void> deleteMessage(String msgId);
  Future<void> updateStatus(String msgId, MessageStatus status);
  Future<void> replaceLocalWithServer(
      String localId, String serverId, DateTime serverCreatedAt);

  // === 消息读取 ===
  Future<List<ChatMessage>> getMessages({
    required String conversationId,
    int limit = 100,
    DateTime? before,
    DateTime? after,
  });

  // === 会话级元数据 ===
  Future<DateTime?> getLastMessageAt(String conversationId);
  /// 单条会话元数据缓存(独立于 conversations 表,不被 putConversations 影响)。
  /// 用于 agent_session 的 convType/title 离线兜底(防止闪头像)。
  Future<void> putConversationMeta(String ownerId, String convId, String type, String? title);
  Future<({String type, String? title})?> getConversationMeta(String ownerId, String convId);

  /// 会话输入框草稿(draft:{ownerId}:{convId},未发送文本本地持久化)。
  /// 空文本不写(用 deleteDraft 表达清除语义)。
  Future<void> putDraft(String ownerId, String convId, String text);
  Future<String?> getDraft(String ownerId, String convId);
  Future<void> deleteDraft(String ownerId, String convId);

  /// 小程序授权能力集(mp_perm:{ownerId}:{appid},KVS 持久化)。
  /// 未记录返空集;解析失败由实现内部兜底返空集,不抛。
  Future<Set<String>> getMpPerms(String ownerId, String appid);
  Future<void> putMpPerms(String ownerId, String appid, Set<String> perms);
  Future<void> deleteMpPerms(String ownerId, String appid); // 幂等

  // === 全局元数据 ===
  Future<int?> getGlobalLastSeq();
  Future<void> setGlobalLastSeq(int seq);

  // === 维护 ===
  Future<void> clearConversation(String conversationId);
  Future<void> clearAll();

  // === F5: 列表缓存(4 张表)==
  Future<void> putConversations(String ownerId, Iterable<model.Conversation> items);
  Future<List<model.Conversation>> getConversations(String ownerId);
  Future<void> putConversation(String ownerId, model.Conversation item); // 单条 upsert(WS 用)
  // 单条查(agent_session 被 ListForUser 排除,不进 getConversations,需独立查)。
  Future<model.Conversation?> getConversation(String ownerId, String convId);

  Future<void> putAgents(String ownerId, Iterable<model.Agent> items);
  Future<List<model.Agent>> getAgents(String ownerId);
  Future<void> putAgent(String ownerId, model.Agent item);

  Future<void> putFriends(String ownerId, Iterable<UserSummary> items);
  Future<List<UserSummary>> getFriends(String ownerId);

  Future<void> putFriendRequests(String ownerId, String direction, Iterable<model.FriendRequest> items);
  Future<List<model.FriendRequest>> getFriendRequests(String ownerId, String direction);

  Future<void> clearLists(String ownerId);
}
