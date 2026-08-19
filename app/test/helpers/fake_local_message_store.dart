import 'package:wanling_core/models/agent.dart' as model;
import 'package:wanling_core/models/conversation.dart' as model;
import 'package:wanling_core/models/friendship.dart' as model;
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/user_summary.dart';
import 'package:wanling_core/services/local_message_store_abstract.dart';

/// 测试用 fake。内存维护,支持 throwOnNextOp 注入失败。
///
/// 数据按 convId 分桶;每桶内按 createdAt DESC 排序(与 drift 实现一致)。
class FakeLocalMessageStore implements LocalMessageStore {
  final Map<String, List<ChatMessage>> _buckets = {};
  int? _globalLastSeq;
  String? _throwOnNextOp; // 设值后下一次任意方法抛错,然后清除

  /// 测试钩子:设值后下一次方法调用抛 Exception,然后自动清除。
  set throwOnNextOp(String op) => _throwOnNextOp = op;

  void _maybeThrow(String op) {
    if (_throwOnNextOp == op) {
      _throwOnNextOp = null;
      throw Exception('fake throw on $op');
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> putMessage(ChatMessage msg) async {
    _maybeThrow('putMessage');
    final bucket = _buckets.putIfAbsent(msg.conversationId, () => []);
    bucket.removeWhere((m) => m.id == msg.id);
    bucket.add(msg);
    bucket.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<void> putMessages(Iterable<ChatMessage> msgs) async {
    _maybeThrow('putMessages');
    for (final m in msgs) {
      final bucket = _buckets.putIfAbsent(m.conversationId, () => []);
      bucket.removeWhere((e) => e.id == m.id);
      bucket.add(m);
    }
    for (final bucket in _buckets.values) {
      bucket.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
  }

  @override
  Future<void> updateContent(String msgId, Map<String, dynamic> content) async {
    _maybeThrow('updateContent');
    for (final bucket in _buckets.values) {
      final idx = bucket.indexWhere((m) => m.id == msgId);
      if (idx >= 0) {
        bucket[idx] = bucket[idx].copyWith(content: content);
        return;
      }
    }
  }

  @override
  Future<void> markRecalled(String msgId, {String recalledByName = ''}) async {
    _maybeThrow('markRecalled');
    for (final bucket in _buckets.values) {
      final idx = bucket.indexWhere((m) => m.id == msgId);
      if (idx >= 0) {
        bucket[idx] = bucket[idx].copyWith(
            isRecalled: true, recalledByName: recalledByName);
        return;
      }
    }
  }

  @override
  Future<void> deleteMessage(String msgId) async {
    _maybeThrow('deleteMessage');
    for (final bucket in _buckets.values) {
      bucket.removeWhere((m) => m.id == msgId);
    }
  }

  @override
  Future<void> updateStatus(String msgId, MessageStatus status) async {
    _maybeThrow('updateStatus');
    for (final bucket in _buckets.values) {
      final idx = bucket.indexWhere((m) => m.id == msgId);
      if (idx >= 0) {
        bucket[idx] = bucket[idx].copyWith(status: status);
        return;
      }
    }
  }

  @override
  Future<void> replaceLocalWithServer(
      String localId, String serverId, DateTime serverCreatedAt) async {
    _maybeThrow('replaceLocalWithServer');
    for (final bucket in _buckets.values) {
      final idx = bucket.indexWhere((m) => m.id == localId);
      if (idx >= 0) {
        bucket[idx] = bucket[idx].copyWith(
            id: serverId,
            createdAt: serverCreatedAt,
            status: MessageStatus.sent);
        bucket.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        return;
      }
    }
  }

  @override
  Future<List<ChatMessage>> getMessages({
    required String conversationId,
    int limit = 100,
    DateTime? before,
    DateTime? after,
  }) async {
    _maybeThrow('getMessages');
    final bucket = _buckets[conversationId] ?? [];
    var filtered = bucket.where((m) {
      if (before != null && !m.createdAt.isBefore(before)) return false;
      if (after != null && !m.createdAt.isAfter(after)) return false;
      return true;
    }).toList();
    return filtered.take(limit).toList();
  }

  @override
  Future<DateTime?> getLastMessageAt(String conversationId) async {
    final bucket = _buckets[conversationId];
    if (bucket == null || bucket.isEmpty) return null;
    return bucket.first.createdAt; // 已按 DESC 排序,first = 最新
  }

  @override
  Future<int?> getGlobalLastSeq() async => _globalLastSeq;

  @override
  Future<void> setGlobalLastSeq(int seq) async {
    _globalLastSeq = seq;
  }

  @override
  Future<void> clearConversation(String conversationId) async {
    _buckets.remove(conversationId);
  }

  @override
  Future<void> clearAll() async {
    _buckets.clear();
    _globalLastSeq = null;
  }

  // === 列表缓存 + conv_meta ===
  final Map<String, List<model.Conversation>> _convByOwner = {};
  final Map<String, List<model.Agent>> _agentsByOwner = {};
  final Map<String, List<UserSummary>> _friendsByOwner = {};
  final Map<String, List<model.FriendRequest>> _incomingByOwner = {};
  final Map<String, List<model.FriendRequest>> _outgoingByOwner = {};
  /// conv_meta 命名空间 key="{ownerId}:{convId}"
  final Map<String, ({String type, String? title})> _convMeta = {};

  @override
  Future<void> putConversations(String ownerId, Iterable<model.Conversation> items) async {
    _maybeThrow('putConversations');
    _convByOwner[ownerId] = List.of(items);
  }

  @override
  Future<List<model.Conversation>> getConversations(String ownerId) async {
    _maybeThrow('getConversations');
    return List.of(_convByOwner[ownerId] ?? []);
  }

  @override
  Future<void> putConversation(String ownerId, model.Conversation item) async {
    _maybeThrow('putConversation');
    final list = _convByOwner.putIfAbsent(ownerId, () => []);
    list.removeWhere((c) => c.id == item.id);
    list.add(item);
  }

  @override
  Future<model.Conversation?> getConversation(String ownerId, String convId) async {
    _maybeThrow('getConversation');
    final list = _convByOwner[ownerId] ?? [];
    for (final c in list) {
      if (c.id == convId) return c;
    }
    return null;
  }

  @override
  Future<void> putAgents(String ownerId, Iterable<model.Agent> items) async {
    _maybeThrow('putAgents');
    _agentsByOwner[ownerId] = List.of(items);
  }

  @override
  Future<List<model.Agent>> getAgents(String ownerId) async {
    _maybeThrow('getAgents');
    return List.of(_agentsByOwner[ownerId] ?? []);
  }

  @override
  Future<void> putAgent(String ownerId, model.Agent item) async {
    _maybeThrow('putAgent');
    final list = _agentsByOwner.putIfAbsent(ownerId, () => []);
    list.removeWhere((a) => a.id == item.id);
    list.add(item);
  }

  @override
  Future<void> putFriends(String ownerId, Iterable<UserSummary> items) async {
    _maybeThrow('putFriends');
    _friendsByOwner[ownerId] = List.of(items);
  }

  @override
  Future<List<UserSummary>> getFriends(String ownerId) async {
    _maybeThrow('getFriends');
    return List.of(_friendsByOwner[ownerId] ?? []);
  }

  @override
  Future<void> putFriendRequests(String ownerId, String direction, Iterable<model.FriendRequest> items) async {
    _maybeThrow('putFriendRequests');
    final map = direction == 'incoming' ? _incomingByOwner : _outgoingByOwner;
    map[ownerId] = List.of(items);
  }

  @override
  Future<List<model.FriendRequest>> getFriendRequests(String ownerId, String direction) async {
    _maybeThrow('getFriendRequests');
    final map = direction == 'incoming' ? _incomingByOwner : _outgoingByOwner;
    return List.of(map[ownerId] ?? []);
  }

  @override
  Future<void> clearLists(String ownerId) async {
    _maybeThrow('clearLists');
    _convByOwner.remove(ownerId);
    _agentsByOwner.remove(ownerId);
    _friendsByOwner.remove(ownerId);
    _incomingByOwner.remove(ownerId);
    _outgoingByOwner.remove(ownerId);
    _convMeta.remove(ownerId);
  }

  @override
  Future<void> putConversationMeta(String ownerId, String convId, String type, String? title) async {
    _maybeThrow('putConversationMeta');
    _convMeta['$ownerId:$convId'] = (type: type, title: title);
  }

  @override
  Future<({String type, String? title})?> getConversationMeta(String ownerId, String convId) async {
    _maybeThrow('getConversationMeta');
    final entry = _convMeta['$ownerId:$convId'];
    if (entry == null) return null;
    return (type: entry.type, title: entry.title);
  }
}
