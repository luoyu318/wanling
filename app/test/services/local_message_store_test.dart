import 'package:app/models/agent.dart' as model;
import 'package:app/models/conversation.dart' as model;
import 'package:app/models/friendship.dart' as model;
import 'package:app/models/message.dart';
import 'package:app/models/user_summary.dart';
import 'package:app/services/local_message_store.dart';
import 'package:drift/drift.dart' show Variable, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late LocalMessageDatabase db;

  setUp(() {
    db = LocalMessageDatabase(NativeDatabase.memory());
  });
  tearDown(() async => await db.close());

  test('putMessage + getMessages 按 created_at DESC 排序', () async {
    final older = _mkMsg('id1', 'conv1', createdAt: DateTime(2026, 7, 1));
    final newer = _mkMsg('id2', 'conv1', createdAt: DateTime(2026, 7, 5));
    await db.putMessage(older);
    await db.putMessage(newer);

    final result = await db.getMessages(conversationId: 'conv1');
    expect(result.length, 2);
    expect(result.first.id, 'id2'); // newest first
    expect(result.last.id, 'id1');
  });

  test('getMessages before / after 过滤', () async {
    final m1 = _mkMsg('id1', 'conv1', createdAt: DateTime(2026, 7, 1));
    final m2 = _mkMsg('id2', 'conv1', createdAt: DateTime(2026, 7, 3));
    final m3 = _mkMsg('id3', 'conv1', createdAt: DateTime(2026, 7, 5));
    await db.putMessages([m1, m2, m3]);

    final before = await db.getMessages(
        conversationId: 'conv1', before: DateTime(2026, 7, 4));
    expect(before.map((m) => m.id), ['id2', 'id1']);

    final after = await db.getMessages(
        conversationId: 'conv1', after: DateTime(2026, 7, 2));
    expect(after.map((m) => m.id), ['id3', 'id2']);
  });

  test('putMessages batch 原子', () async {
    final batch = List.generate(
        100,
        (i) => _mkMsg('id$i', 'conv1',
            createdAt: DateTime(2026, 7, 1).add(Duration(minutes: i))));
    await db.putMessages(batch);
    final result = await db.getMessages(conversationId: 'conv1', limit: 200);
    expect(result.length, 100);
  });

  test('idx_messages_conv_created 索引存在', () async {
    final plan = await db.customSelect(
      'EXPLAIN QUERY PLAN SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at DESC',
      variables: [Variable.withString('conv1')],
    ).get();
    final planStr = plan.map((r) => r.data['detail']).join('\n');
    expect(planStr, contains('idx_messages_conv_created'));
  });

  test('单条坏 content 不拖垮整批(silently fallback)', () async {
    // 写两条正常 + 一条坏 content(非 JSON)
    await db.putMessage(_mkMsg('good1', 'conv1', createdAt: DateTime(2026, 7, 1)));
    await db.putMessage(_mkMsg('good2', 'conv1', createdAt: DateTime(2026, 7, 2)));
    // 直接写坏 content(绕过 _toRow 的 jsonEncode)
    await db.customStatement(
        "INSERT INTO messages (id, conversation_id, sender_type, sender_id, content, created_at, status, is_recalled, recalled_by_name, updated_at) VALUES ('bad', 'conv1', 'user', 'uid', 'NOT_JSON', 1000, 'sent', 0, '', 1000)");

    final result = await db.getMessages(conversationId: 'conv1');
    // bad 那条被跳过,只剩 good1 + good2
    expect(result.length, 2);
    expect(result.map((m) => m.id).toList(), containsAll(['good1', 'good2']));
    expect(result.any((m) => m.id == 'bad'), false);
  });

  test('未知 status 值兜底为 sent(防御性 _parseStatus)', () async {
    await db.customStatement(
        "INSERT INTO messages (id, conversation_id, sender_type, sender_id, content, created_at, status, is_recalled, recalled_by_name, updated_at) VALUES ('m1', 'conv1', 'user', 'uid', '{}', 1000, 'unknown_status', 0, '', 1000)");

    final result = await db.getMessages(conversationId: 'conv1');
    expect(result.length, 1);
    expect(result.first.status, MessageStatus.sent); // 兜底
  });

  test('recalledByName 空串还原为 null(语义一致)', () async {
    await db.putMessage(_mkMsg('m1', 'conv1', createdAt: DateTime(2026, 7, 1)));
    // 直接 update isRecalled=true, recalledByName=''
    await db.customStatement(
        "UPDATE messages SET is_recalled = 1, recalled_by_name = '' WHERE id = 'm1'");
    final result = await db.getMessages(conversationId: 'conv1');
    expect(result.first.isRecalled, true);
    expect(result.first.recalledByName, isNull); // '' → null
  });

  test('updateContent 修改消息 content', () async {
    await db.putMessage(_mkMsg('id1', 'conv1', createdAt: DateTime(2026, 7, 1)));
    await db.updateContent('id1', {'msg_type': 'text', 'data': {'text': 'edited'}});
    final result = await db.getMessages(conversationId: 'conv1');
    expect(result.first.content['data']['text'], 'edited');
  });

  test('markRecalled 切 isRecalled + recalledByName', () async {
    await db.putMessage(_mkMsg('id1', 'conv1', createdAt: DateTime(2026, 7, 1)));
    await db.markRecalled('id1', recalledByName: 'Alice');
    final result = await db.getMessages(conversationId: 'conv1');
    expect(result.first.isRecalled, true);
    expect(result.first.recalledByName, 'Alice');
  });

  test('deleteMessage 移除消息', () async {
    await db.putMessage(_mkMsg('id1', 'conv1', createdAt: DateTime(2026, 7, 1)));
    await db.deleteMessage('id1');
    final result = await db.getMessages(conversationId: 'conv1');
    expect(result, isEmpty);
  });

  test('updateStatus 切 status 列', () async {
    await db.putMessage(_mkMsg('id1', 'conv1', createdAt: DateTime(2026, 7, 1)));
    await db.updateStatus('id1', MessageStatus.failed);
    final result = await db.getMessages(conversationId: 'conv1');
    expect(result.first.status, MessageStatus.failed);
  });

  test('replaceLocalWithServer 单事务原子(改 id + 切 sent)', () async {
    final local = _mkMsg('local_1', 'conv1', createdAt: DateTime(2026, 7, 1));
    await db.putMessage(local);
    final serverCreatedAt = DateTime(2026, 7, 2);
    await db.replaceLocalWithServer('local_1', 'server_uuid', serverCreatedAt);
    final result = await db.getMessages(conversationId: 'conv1');
    expect(result.length, 1);
    expect(result.first.id, 'server_uuid');
    expect(result.first.status, MessageStatus.sent);
    expect(result.first.createdAt, serverCreatedAt);
  });

  test('replaceLocalWithServer localId 不存在时不动数据库', () async {
    await db.replaceLocalWithServer(
        'nonexistent', 'server_uuid', DateTime(2026, 7, 2));
    final result = await db.getMessages(conversationId: 'conv1');
    expect(result, isEmpty); // 不该误插 server_uuid 行
  });

  test('getLastMessageAt 返回最新消息 created_at', () async {
    await db.putMessage(_mkMsg('id1', 'conv1', createdAt: DateTime(2026, 7, 1)));
    await db.putMessage(_mkMsg('id2', 'conv1', createdAt: DateTime(2026, 7, 5)));
    final latest = await db.getLastMessageAt('conv1');
    expect(latest, DateTime(2026, 7, 5));
  });

  test('getLastMessageAt 空会话返回 null', () async {
    final latest = await db.getLastMessageAt('conv_empty');
    expect(latest, isNull);
  });

  test('global_last_seq 存取(kv 表)', () async {
    expect(await db.getGlobalLastSeq(), isNull);
    await db.setGlobalLastSeq(42);
    expect(await db.getGlobalLastSeq(), 42);
  });

  test('setGlobalLastSeq 单调 max(乱序到达不倒退)', () async {
    await db.setGlobalLastSeq(100);
    await db.setGlobalLastSeq(95); // 乱序晚到的较小值
    expect(await db.getGlobalLastSeq(), 100); // 仍为 100,不倒退

    await db.setGlobalLastSeq(200);
    expect(await db.getGlobalLastSeq(), 200); // 更大值正常推进
  });

  test('clearConversation 仅清当前会话', () async {
    await db.putMessage(_mkMsg('id1', 'conv1', createdAt: DateTime(2026, 7, 1)));
    await db.putMessage(_mkMsg('id2', 'conv2', createdAt: DateTime(2026, 7, 1)));
    await db.clearConversation('conv1');
    expect(await db.getMessages(conversationId: 'conv1'), isEmpty);
    expect((await db.getMessages(conversationId: 'conv2')).length, 1);
  });

  test('clearAll 清全部', () async {
    await db.putMessage(_mkMsg('id1', 'conv1', createdAt: DateTime(2026, 7, 1)));
    await db.setGlobalLastSeq(99);
    await db.clearAll();
    expect(await db.getMessages(conversationId: 'conv1'), isEmpty);
    expect(await db.getGlobalLastSeq(), isNull);
  });

  // F5 新增测试组(用独立 setUp 避免共享 state)
  group('F5: schemaVersion 2 + 4 张新表', () {
    late LocalMessageDatabase db;
    setUp(() {
      db = LocalMessageDatabase(NativeDatabase.memory());
    });
    tearDown(() async => await db.close());

    test('schemaVersion 应为 7', () async {
      expect(db.schemaVersion, 7);
    });

    test('新表 conversations 存在', () async {
      final rows = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='conversations'",
      ).get();
      expect(rows.length, 1);
    });

    test('新表 agents 存在', () async {
      final rows = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='agents'",
      ).get();
      expect(rows.length, 1);
    });

    test('新表 friends 存在', () async {
      final rows = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='friends'",
      ).get();
      expect(rows.length, 1);
    });

    test('新表 friend_requests 存在', () async {
      final rows = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='friend_requests'",
      ).get();
      expect(rows.length, 1);
    });
  });

  group('F5: 列表缓存表 CRUD', () {
    late LocalMessageDatabase db;
    setUp(() {
      db = LocalMessageDatabase(NativeDatabase.memory());
    });
    tearDown(() async => await db.close());

    test('Conversations 表 put/get 往返', () async {
      final conv = model.Conversation(
        id: 'c1',
        type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: {'msg_type': 'text', 'data': {'text': 'hi'}},
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
        unreadCount: 3,
      );
      await db.putConversations('u1', [conv]);
      final got = await db.getConversations('u1');
      expect(got.length, 1);
      expect(got.first.id, 'c1');
      expect(got.first.unreadCount, 3);
    });

    test('Conversations 按 ownerId 隔离', () async {
      final conv = model.Conversation(
        id: 'c1', type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
      );
      await db.putConversations('u1', [conv]);
      final gotU2 = await db.getConversations('u2');
      expect(gotU2, isEmpty);
    });

    test('putConversation 单条 upsert(WS 事件用)', () async {
      final conv = model.Conversation(
        id: 'c1', type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
        unreadCount: 1,
      );
      await db.putConversation('u1', conv);
      final updated = conv.copyWith(unreadCount: 5);
      await db.putConversation('u1', updated);
      final got = await db.getConversations('u1');
      expect(got.length, 1);
      expect(got.first.unreadCount, 5);
    });

    test('getConversation 单条查(agent_session 被 ListForUser 排除,需独立查)', () async {
      final conv = model.Conversation(
        id: 'cAS', type: 'agent_session',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
      );
      await db.putConversation('u1', conv);
      final got = await db.getConversation('u1', 'cAS');
      expect(got, isNotNull);
      expect(got!.id, 'cAS');
      expect(got.type, 'agent_session');
    });

    test('getConversation 单条查不存在返 null', () async {
      final got = await db.getConversation('u1', 'nope');
      expect(got, isNull);
    });

    test('getConversation 按 ownerId 隔离', () async {
      final conv = model.Conversation(
        id: 'c1', type: 'agent_session',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
      );
      await db.putConversation('u1', conv);
      final got = await db.getConversation('u2', 'c1');
      expect(got, isNull);
    });

    test('Agents 表 put/get 往返', () async {
      final agent = model.Agent(
        id: 'a1', name: 'Bot', avatarUrl: 'http://a',
        bio: 'hi', status: model.AgentStatus.online,
      );
      await db.putAgents('u1', [agent]);
      final got = await db.getAgents('u1');
      expect(got.length, 1);
      expect(got.first.name, 'Bot');
    });

    test('Friends 表 put/get 往返', () async {
      final friend = UserSummary(username: 'bob', nickname: 'Bob', avatarUrl: '');
      await db.putFriends('u1', [friend]);
      final got = await db.getFriends('u1');
      expect(got.length, 1);
      expect(got.first.username, 'bob');
    });

    test('FriendRequests 表 incoming/outgoing 隔离', () async {
      final req = model.FriendRequest(
        id: 'r1', status: model.FriendshipStatus.pending,
        createdAt: DateTime.utc(2026, 7, 5),
        user: UserSummary(username: 'bob', nickname: 'Bob', avatarUrl: ''),
      );
      await db.putFriendRequests('u1', 'incoming', [req]);
      await db.putFriendRequests('u1', 'outgoing', []);
      final incoming = await db.getFriendRequests('u1', 'incoming');
      final outgoing = await db.getFriendRequests('u1', 'outgoing');
      expect(incoming.length, 1);
      expect(outgoing, isEmpty);
    });

    test('clearLists 清 4 张表', () async {
      // 4 张表各放一条数据
      await db.putConversations('u1', [model.Conversation(
        id: 'c1', type: 'dm_user_agent', participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
      )]);
      await db.putAgents('u1', [model.Agent(id: 'a1', name: 'B', status: model.AgentStatus.offline)]);
      await db.putFriends('u1', [UserSummary(username: 'bob', nickname: 'Bob', avatarUrl: '')]);
      await db.putFriendRequests('u1', 'incoming', [model.FriendRequest(
        id: 'r1', status: model.FriendshipStatus.pending,
        createdAt: DateTime.utc(2026, 7, 5),
        user: UserSummary(username: 'alice', nickname: 'A', avatarUrl: ''),
      )]);

      await db.clearLists('u1');

      // 4 张表都应该被清空
      expect(await db.getConversations('u1'), isEmpty);
      expect(await db.getAgents('u1'), isEmpty);
      expect(await db.getFriends('u1'), isEmpty);
      expect(await db.getFriendRequests('u1', 'incoming'), isEmpty);
    });
  });

  // v5 migration 清理脏数据:parent_msg_id IS NULL 的审批卡。
  // 模拟 v4→v5 升级:onUpgrade 跑清理 SQL,验证脏行被删、正常消息保留。
  group('v5 migration 清理脏审批卡', () {
    test('parent_msg_id IS NULL 的 permission_card/question_card 被删', () async {
      // 脏数据:parent_msg_id IS NULL 的终态审批卡(v4 残留,parent 丢失)
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('dirty1','c1','agent','a1','{\"msg_type\":\"permission_card\",\"data\":{\"status\":\"approved\"}}',"
          "0,'sent',0,'',NULL,0)");
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('dirty2','c1','agent','a1','{\"msg_type\":\"question_card\",\"data\":{\"status\":\"pending\"}}',"
          "1,'sent',0,'',NULL,0)");
      // 正常消息:普通文本(parent NULL,但不是审批卡)→ 保留
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('normal1','c1','user','u1','{\"msg_type\":\"text\",\"data\":{\"text\":\"hi\"}}',"
          "2,'sent',0,'',NULL,0)");
      // 正常审批卡:parent_msg_id 非空 → 保留
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('clean1','c1','agent','a1','{\"msg_type\":\"permission_card\",\"data\":{\"status\":\"pending\"}}',"
          "3,'sent',0,'','parent-id',0)");

      // 执行 v5 清理 SQL(与 migration from<5 完全一致)
      await db.customStatement(
          "DELETE FROM messages WHERE parent_msg_id IS NULL AND "
          "(content LIKE '%\"msg_type\":\"permission_card\"%' OR "
          "content LIKE '%\"msg_type\":\"question_card\"%')");

      final remaining = await db.customSelect(
          'SELECT id FROM messages ORDER BY id').get();
      final ids = remaining.map((r) => r.read<String>('id')).toSet();
      expect(ids, {'normal1', 'clean1'});
      expect(ids, isNot(contains('dirty1')));
      expect(ids, isNot(contains('dirty2')));
    });
  });

  // v6 migration 清理 v5 LIKE 漏掉的脏数据。
  // v5 用 content LIKE '%\"msg_type\":\"permission_card\"%' 清理,但实际设备上
  // JSON 序列化格式可能有差异(空格/引号),导致 LIKE 不匹配。v6 改用 json_extract
  // 精确提取 $.msg_type 字段比对,覆盖所有已升 v5 但脏数据残留的设备。
  group('v6 migration 清理 v5 LIKE 漏掉的脏审批卡', () {
    test('json_extract 清掉 v5 LIKE 漏掉的格式(含空格的 JSON)', () async {
      // 模拟 v5 LIKE 漏掉的脏数据:JSON 键值间含空格(v5 的 LIKE 模式无空格匹配失败)
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('dirty-space','c1','agent','a1','{\"msg_type\": \"permission_card\", \"data\": {\"status\": \"approved\"}}',"
          "0,'sent',0,'',NULL,0)");
      // 正常消息:普通文本(parent NULL,但不是审批卡)→ 保留
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('normal1','c1','user','u1','{\"msg_type\":\"text\",\"data\":{\"text\":\"hi\"}}',"
          "2,'sent',0,'',NULL,0)");
      // 正常审批卡:parent_msg_id 非空 → 保留
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('clean1','c1','agent','a1','{\"msg_type\": \"permission_card\", \"data\": {\"status\": \"pending\"}}',"
          "3,'sent',0,'','parent-id',0)");

      // 执行 v6 清理 SQL(与 migration from<6 完全一致)
      await db.customStatement(
          "DELETE FROM messages WHERE parent_msg_id IS NULL AND "
          "json_extract(content, '\$.msg_type') IN "
          "('permission_card', 'question_card')");

      final remaining = await db.customSelect(
          'SELECT id FROM messages ORDER BY id').get();
      final ids = remaining.map((r) => r.read<String>('id')).toSet();
      expect(ids, {'normal1', 'clean1'});
      expect(ids, isNot(contains('dirty-space')));
    });
  });

  // v7 migration: 终态子审批卡漏出主会话框的彻底清理。
  // v6 升级后部分设备 DB 仍有 parent_msg_id IS NULL 的审批卡行(早期版本写入的
  // 残留 + _mergeHistory 旧实现回写)。v7 再清一次 + 修 _mergeHistory
  // 打破自维持脏数据循环。
  group('v7 migration 清理终态子审批卡脏数据', () {
    test('清掉 parent=NULL 的审批卡(子 agent 事件残留),保留主 session 顶层卡', () async {
      // 脏数据 1:parent=NULL 的终态 permission_card(应被清)
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('dirty-pc','c1','agent','a1','{\"msg_type\":\"permission_card\",\"data\":{\"status\":\"approved\"}}',"
          "0,'sent',0,'',NULL,0)");
      // 脏数据 2:parent=NULL 的 question_card(应被清)
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('dirty-qc','c1','agent','a1','{\"msg_type\":\"question_card\",\"data\":{\"status\":\"answered\"}}',"
          "1,'sent',0,'',NULL,0)");
      // 正常消息:普通文本 → 保留
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('text1','c1','user','u1','{\"msg_type\":\"text\",\"data\":{\"text\":\"hi\"}}',"
          "2,'sent',0,'',NULL,0)");
      // 正常子审批卡:parent 非空 → 保留(loadMoreHistory 写入的合法 server 数据)
      await db.customStatement(
          "INSERT INTO messages (id, conversation_id, sender_type, sender_id, "
          "content, created_at, status, is_recalled, recalled_by_name, parent_msg_id, updated_at) "
          "VALUES ('clean-child-pc','c1','agent','a1','{\"msg_type\":\"permission_card\",\"data\":{\"status\":\"approved\"}}',"
          "3,'sent',0,'','parent-1',0)");

      // 执行 v7 清理 SQL(与 migration from<7 完全一致)
      await db.customStatement(
          "DELETE FROM messages WHERE parent_msg_id IS NULL AND "
          "json_extract(content, '\$.msg_type') IN "
          "('permission_card', 'question_card')");

      final remaining = await db.customSelect(
          'SELECT id FROM messages ORDER BY id').get();
      final ids = remaining.map((r) => r.read<String>('id')).toSet();
      // 脏数据被清,正常消息 + 正常子审批卡保留
      expect(ids, {'text1', 'clean-child-pc'});
      expect(ids, isNot(contains('dirty-pc')));
      expect(ids, isNot(contains('dirty-qc')));
    });
  });

// 聚合卡空中间态(generating + 无 elements)不缓存:重进读到会渲染空白。
test('空聚合卡中间态不写库,完整卡正常写', () async {
  final emptyAgg = _mkAggregateCard('empty-agg', 'conv1',
      createdAt: DateTime(2026, 7, 2), state: 'generating', elems: 0);
  final fullAgg = _mkAggregateCard('full-agg', 'conv1',
      createdAt: DateTime(2026, 7, 3), state: 'done', elems: 5);
  final text = _mkMsg('txt', 'conv1', createdAt: DateTime(2026, 7, 1));

  await db.putMessages([emptyAgg, fullAgg, text]);

  final result = await db.getMessages(conversationId: 'conv1', limit: 100);
  final ids = result.map((m) => m.id).toSet();
  expect(ids, isNot(contains('empty-agg')), reason: '空聚合卡不写库');
  expect(ids, contains('full-agg'), reason: 'done 完整聚合卡写库');
  expect(ids, contains('txt'));
});

// done 但 elements 空的聚合卡也要写(终态判定优先于空判定)。
test('done 聚合卡即使 elements 空也写库', () async {
  final doneEmpty = _mkAggregateCard('done-empty', 'conv1',
      createdAt: DateTime(2026, 7, 1), state: 'done', elems: 0);
  await db.putMessage(doneEmpty);
  final result = await db.getMessages(conversationId: 'conv1');
  expect(result.map((m) => m.id), contains('done-empty'));
});
}

ChatMessage _mkMsg(String id, String convId, {required DateTime createdAt}) {
  return ChatMessage(
    id: id,
    conversationId: convId,
    senderType: 'user',
    senderId: 'uid',
    content: {'msg_type': 'text', 'data': {'text': 'hi'}},
    isRead: true,
    createdAt: createdAt,
    status: MessageStatus.sent,
  );
}

ChatMessage _mkAggregateCard(String id, String convId,
    {required DateTime createdAt,
    required String state,
    required int elems}) {
  return ChatMessage(
    id: id,
    conversationId: convId,
    senderType: 'agent',
    senderId: 'agent-1',
    content: {
      'msg_type': 'aggregate_card',
      'data': {
        'state': state,
        'elements': List.generate(
          elems,
          (i) => {
            'type': 'markdown',
            'element_id': 'markdown_${i + 1}',
            'data': {'text': '内容 $i'},
          },
        ),
      },
    },
    isRead: true,
    createdAt: createdAt,
    status: MessageStatus.sent,
  );
}


