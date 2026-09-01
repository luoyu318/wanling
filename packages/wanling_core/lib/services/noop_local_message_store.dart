import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/friendship.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/user_summary.dart';
import 'local_message_store_abstract.dart';

/// store 加载中 / 失败时用,所有方法 noop。让 provider 走纯 API 模式。
///
/// 设计目的:
/// - localMessageStoreProvider 是 FutureProvider,加载中或失败时返 null/error
/// - provider 拿不到 store 实例时,用 NoopLocalMessageStore 占位
/// - NoopLocalMessageStore 所有方法 noop / 返空,不阻塞 provider 主流程
class NoopLocalMessageStore implements LocalMessageStore {
  @override
  Future<void> close() async {}

  @override
  Future<void> putMessage(ChatMessage msg) async {}

  @override
  Future<void> putMessages(Iterable<ChatMessage> msgs) async {}

  @override
  Future<void> updateContent(String msgId, Map<String, dynamic> content) async {}

  @override
  Future<void> markRecalled(String msgId, {String recalledByName = ''}) async {}

  @override
  Future<void> deleteMessage(String msgId) async {}

  @override
  Future<void> updateStatus(String msgId, MessageStatus status) async {}

  @override
  Future<void> replaceLocalWithServer(
      String localId, String serverId, DateTime serverCreatedAt) async {}

  @override
  Future<List<ChatMessage>> getMessages({
    required String conversationId,
    int limit = 100,
    DateTime? before,
    DateTime? after,
  }) async => [];

  @override
  Future<DateTime?> getLastMessageAt(String conversationId) async => null;

  @override
  Future<int?> getGlobalLastSeq() async => null;

  @override
  Future<void> setGlobalLastSeq(int seq) async {}

  @override
  Future<String?> getMpSigningPubKey() async => null;

  @override
  Future<void> putMpSigningPubKey(String pubHex) async {}

  @override
  Future<void> clearConversation(String conversationId) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<void> putConversations(String ownerId, Iterable<Conversation> items) async {}

  @override
  Future<List<Conversation>> getConversations(String ownerId) async => [];

  @override
  Future<void> putConversation(String ownerId, Conversation item) async {}

  @override
  Future<Conversation?> getConversation(String ownerId, String convId) async => null;

  @override
  Future<void> putAgents(String ownerId, Iterable<Agent> items) async {}

  @override
  Future<List<Agent>> getAgents(String ownerId) async => [];

  @override
  Future<void> putAgent(String ownerId, Agent item) async {}

  @override
  Future<void> putFriends(String ownerId, Iterable<UserSummary> items) async {}

  @override
  Future<List<UserSummary>> getFriends(String ownerId) async => [];

  @override
  Future<void> putFriendRequests(String ownerId, String direction, Iterable<FriendRequest> items) async {}

  @override
  Future<List<FriendRequest>> getFriendRequests(String ownerId, String direction) async => [];

  @override
  Future<void> putConversationMeta(String ownerId, String convId, String type, String? title) async {}

  @override
  Future<({String type, String? title})?> getConversationMeta(String ownerId, String convId) async => null;

  @override
  Future<void> putDraft(String ownerId, String convId, String text) async {}

  @override
  Future<String?> getDraft(String ownerId, String convId) async => null;

  @override
  Future<void> deleteDraft(String ownerId, String convId) async {}

  @override
  Future<Set<String>> getMpPerms(String ownerId, String appid) async => <String>{};

  @override
  Future<void> putMpPerms(String ownerId, String appid, Set<String> perms) async {}

  @override
  Future<void> deleteMpPerms(String ownerId, String appid) async {}

  @override
  Future<void> clearLists(String ownerId) async {}
}
