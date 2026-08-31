import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/agent.dart' as model;
import 'package:wanling_core/models/conversation.dart' as model;
import 'package:wanling_core/models/friendship.dart' as model;
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/user_summary.dart';
import 'package:wanling_core/services/local_message_store.dart';
import 'package:wanling_core/services/local_message_store_abstract.dart';
import 'auth_provider.dart';

/// 本地消息持久化 Provider。
///
/// - 用 FutureProvider 因 open 是 async(SQLCipher + drift 文件 IO)
/// - select 监听 authProvider.user.id,uid 变化触发 provider 重建
///   (登出 → uid=null → 重建 → throw StateError 进入 error state)
/// - autoDispose:无 listener 时释放(切 tab 离开会话等场景)
/// - Consumer 用 ref.watch(localMessageStoreProvider).when(...) 处理加载态
/// - error state(未登录 / open 二次失败)需上层决定如何呈现给用户
final localMessageStoreProvider =
    FutureProvider.autoDispose<LocalMessageStore>((ref) async {
  final uid = ref.watch(authProvider.select((s) => s.user?.id));
  if (uid == null) throw StateError('未登录,无法打开本地 DB');

  final db = await LocalMessageDatabase.open(uid: uid);
  // Riverpod 2.x onDispose 不 await async 回调,这里同步发起 fire-and-forget
  // 真正的关闭时序保证见 Task 9 启动序列(main.dart await 切换)
  ref.onDispose(() {
    db.close().catchError(
        (e) => debugPrint('[localdb] dispose close fail: $e'));
  });
  return _DriftStoreAdapter(db);
});

/// 包装 drift database 实例,实现 abstract。
/// drift generated code 不直接 implement abstract,用 adapter 桥接。
class _DriftStoreAdapter implements LocalMessageStore {
  final LocalMessageDatabase db;
  _DriftStoreAdapter(this.db);

  @override
  Future<void> close() => db.close();

  @override
  Future<void> putMessage(ChatMessage msg) => db.putMessage(msg);

  @override
  Future<void> putMessages(Iterable<ChatMessage> msgs) => db.putMessages(msgs);

  @override
  Future<void> updateContent(String msgId, Map<String, dynamic> content) =>
      db.updateContent(msgId, content);

  @override
  Future<void> markRecalled(String msgId, {String recalledByName = ''}) =>
      db.markRecalled(msgId, recalledByName: recalledByName);

  @override
  Future<void> deleteMessage(String msgId) => db.deleteMessage(msgId);

  @override
  Future<void> updateStatus(String msgId, MessageStatus status) =>
      db.updateStatus(msgId, status);

  @override
  Future<void> replaceLocalWithServer(
          String localId, String serverId, DateTime serverCreatedAt) =>
      db.replaceLocalWithServer(localId, serverId, serverCreatedAt);

  @override
  Future<List<ChatMessage>> getMessages({
    required String conversationId,
    int limit = 100,
    DateTime? before,
    DateTime? after,
  }) =>
      db.getMessages(
          conversationId: conversationId,
          limit: limit,
          before: before,
          after: after);

  @override
  Future<DateTime?> getLastMessageAt(String conversationId) =>
      db.getLastMessageAt(conversationId);

  @override
  Future<int?> getGlobalLastSeq() => db.getGlobalLastSeq();

  @override
  Future<void> setGlobalLastSeq(int seq) => db.setGlobalLastSeq(seq);

  @override
  Future<void> clearConversation(String conversationId) =>
      db.clearConversation(conversationId);

  @override
  Future<void> clearAll() => db.clearAll();

  @override
  Future<void> putConversations(String ownerId, Iterable<model.Conversation> items) =>
      db.putConversations(ownerId, items);

  @override
  Future<List<model.Conversation>> getConversations(String ownerId) =>
      db.getConversations(ownerId);

  @override
  Future<void> putConversation(String ownerId, model.Conversation item) =>
      db.putConversation(ownerId, item);

  @override
  Future<model.Conversation?> getConversation(String ownerId, String convId) =>
      db.getConversation(ownerId, convId);

  @override
  Future<void> putAgents(String ownerId, Iterable<model.Agent> items) =>
      db.putAgents(ownerId, items);

  @override
  Future<List<model.Agent>> getAgents(String ownerId) => db.getAgents(ownerId);

  @override
  Future<void> putAgent(String ownerId, model.Agent item) => db.putAgent(ownerId, item);

  @override
  Future<void> putFriends(String ownerId, Iterable<UserSummary> items) =>
      db.putFriends(ownerId, items);

  @override
  Future<List<UserSummary>> getFriends(String ownerId) => db.getFriends(ownerId);

  @override
  Future<void> putFriendRequests(String ownerId, String direction, Iterable<model.FriendRequest> items) =>
      db.putFriendRequests(ownerId, direction, items);

  @override
  Future<List<model.FriendRequest>> getFriendRequests(String ownerId, String direction) =>
      db.getFriendRequests(ownerId, direction);

  @override
  Future<void> putConversationMeta(String ownerId, String convId, String type, String? title) =>
      db.putConversationMeta(ownerId, convId, type, title);

  @override
  Future<({String type, String? title})?> getConversationMeta(String ownerId, String convId) =>
      db.getConversationMeta(ownerId, convId);

  @override
  Future<void> putDraft(String ownerId, String convId, String text) =>
      db.putDraft(ownerId, convId, text);

  @override
  Future<String?> getDraft(String ownerId, String convId) =>
      db.getDraft(ownerId, convId);

  @override
  Future<void> deleteDraft(String ownerId, String convId) =>
      db.deleteDraft(ownerId, convId);

  @override
  Future<Set<String>> getMpPerms(String ownerId, String appid) =>
      db.getMpPerms(ownerId, appid);

  @override
  Future<void> putMpPerms(String ownerId, String appid, Set<String> perms) =>
      db.putMpPerms(ownerId, appid, perms);

  @override
  Future<void> deleteMpPerms(String ownerId, String appid) =>
      db.deleteMpPerms(ownerId, appid);

  @override
  Future<void> clearLists(String ownerId) => db.clearLists(ownerId);
}
