import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import '../models/agent.dart' as model;
import '../models/conversation.dart' as model;
import '../models/friendship.dart' as model;
import '../models/message.dart';
import '../models/msg_type.dart';
import '../models/user_summary.dart';
import 'local_message_key.dart';

part 'local_message_store.g.dart';

/// 本地消息表(完整镜像 server messages)
class Messages extends Table {
  TextColumn get id => text()();
  TextColumn get conversationId => text()();
  TextColumn get senderType => text()();
  TextColumn get senderId => text()();
  TextColumn get senderName => text().nullable()();
  TextColumn get senderAvatarUrl => text().nullable()();
  TextColumn get content => text()(); // JSON encode 后的 content Map
  IntColumn get createdAt => integer()(); // Unix milliseconds
  TextColumn get status => text().withDefault(const Constant('sent'))();
  BoolColumn get isRecalled => boolean().withDefault(const Constant(false))();
  TextColumn get recalledByName => text().withDefault(const Constant(''))();

  /// 父/根消息 id（子 agent 事件才有；主对话流消息为 null）。
  /// 用于 getMessages 后 _filterDisplayable 过滤,与 server SQL
  /// `WHERE parent_msg_id IS NULL` 行为对齐,避免 DB 缓存命中时漏过滤。
  TextColumn get parentMsgId => text().nullable()();
  TextColumn get rootMsgId => text().nullable()();

  IntColumn get updatedAt => integer()(); // Unix milliseconds
  @override
  Set<Column> get primaryKey => {id};
}

/// 会话元数据(每会话一行,增量同步用)
class ConversationMetas extends Table {
  TextColumn get conversationId => text()();
  IntColumn get lastMessageAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {conversationId};
}

/// 全局 KV(存 global_last_seq / account_uid 等)
class Kvs extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 会话列表缓存(完整 Conv JSON,按 ownerId 隔离)
class Conversations extends Table {
  TextColumn get id => text()();
  TextColumn get ownerId => text()();
  TextColumn get data => text()(); // JSON encode Conversation
  IntColumn get updatedAt => integer()(); // Unix milliseconds

  @override
  Set<Column> get primaryKey => {id};
}

/// Agent 列表缓存(完整 Agent JSON,按 ownerId 隔离)
class Agents extends Table {
  TextColumn get id => text()();
  TextColumn get ownerId => text()();
  TextColumn get data => text()(); // JSON encode Agent
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 好友列表缓存(完整 UserSummary JSON,按 ownerId 隔离)
class Friends extends Table {
  TextColumn get id => text()();
  TextColumn get ownerId => text()();
  TextColumn get data => text()(); // JSON encode UserSummary
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 好友请求缓存(完整 FriendRequest JSON,按 direction 区分 incoming/outgoing)
class FriendRequests extends Table {
  TextColumn get id => text()();
  TextColumn get ownerId => text()();
  TextColumn get direction => text()(); // 'incoming' | 'outgoing'
  TextColumn get data => text()(); // JSON encode FriendRequest
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(tables: [Messages, ConversationMetas, Kvs, Conversations, Agents, Friends, FriendRequests])
class LocalMessageDatabase extends _$LocalMessageDatabase {
  LocalMessageDatabase(super.e);

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          // 主查询索引:进会话 newest first
          await customStatement(
              'CREATE INDEX IF NOT EXISTS idx_messages_conv_created '
              'ON messages (conversation_id, created_at DESC)');
          debugPrint('[localdb-migra] onCreate: fresh DB at schemaVersion=$schemaVersion');
        },
        onUpgrade: (m, from, to) async {
          debugPrint('[localdb-migra] onUpgrade: from=$from to=$to');
          if (from < 2) {
            // F5: 加 4 张业务列表缓存表
            await m.createTable(conversations);
            await m.createTable(agents);
            await m.createTable(friends);
            await m.createTable(friendRequests);
            // ConversationMetas 保留(F4 单会话游标语义不变)
          }
          if (from < 3) {
            // F6: 加 sender_name/sender_avatar_url 列，修复历史消息空头像
            await customStatement(
                'ALTER TABLE messages ADD COLUMN sender_name TEXT');
            await customStatement(
                'ALTER TABLE messages ADD COLUMN sender_avatar_url TEXT');
          }
          if (from < 4) {
            // 子 agent 事件过滤:加 parent_msg_id/root_msg_id 列。
            // 旧行此列为 NULL(parent_msg_id 由 server WS dispatch 顶层字段透传,
            // v3 schema 没存),旧数据无法回填也无法识别。直接清空 messages 表,
            // 让 _initialize 重新从 server 拉(server ListByConversation 已按
            // parent_msg_id IS NULL 过滤,重拉后的数据天然干净)。
            // 代价:每个会话首次进入重拉一次(原有 fallback 路径,无感)。
            // 保留会话/好友/agent 缓存表(非 messages)不受影响。
            await customStatement(
                'ALTER TABLE messages ADD COLUMN parent_msg_id TEXT');
            await customStatement(
                'ALTER TABLE messages ADD COLUMN root_msg_id TEXT');
            await customStatement('DELETE FROM messages');
          }
          if (from < 5) {
            // 清理脏数据:parent_msg_id IS NULL 的审批卡(permission_card /
            // question_card)。这些行是早期(无 parent_msg_id 列 / 旧 APP 版本
            // fromJson 未解析 parent)写入的残留,后续因审批卡被 _filterDisplayable
            // 过滤后不进 historyMessages,putMessages 从不覆盖,DB 里永远是 NULL。
            // 表现为重进会话时 eager local 读取把它们以 parent=null 填进 state,
            // 经 _mergeHistory 的 extra(不过滤)漏出主会话框。
            // 删掉后 _initialize 重拉从 server 获取正确 parent_msg_id。pending 卡
            // 同删:server ListByConversation(is_main_stream=true)会重拉覆盖,且
            // WS 重连会重新 dispatch 当前 pending 状态,无空窗风险。
            await customStatement(
                "DELETE FROM messages WHERE parent_msg_id IS NULL AND "
                "(content LIKE '%\"msg_type\":\"permission_card\"%' OR "
                "content LIKE '%\"msg_type\":\"question_card\"%')");
          }
          if (from < 6) {
            // v5 的 LIKE 清理在部分设备未生效(JSON 序列化空格/引号差异致匹配失败),
            // 用 json_extract 精确匹配再清一次。覆盖所有已升 v5 但脏数据残留的设备。
            // 根因:子审批卡(parent_msg_id 非空)由 WS MESSAGE_CREATE 到达时被
            // websocket_service:458 跳过入库(parent 非空不存 DB),终态 MESSAGE_UPDATE
            // 调 updateContent 只改 content 不写 parent_msg_id 列。脏行只能由历史版本
            // (无 parent_msg_id 列 / fromJson 未解析)写入,v5 LIKE 未清干净。
            await customStatement(
                "DELETE FROM messages WHERE parent_msg_id IS NULL AND "
                "json_extract(content, '\$.msg_type') IN "
                "('permission_card', 'question_card')");
          }
          if (from < 7) {
            // 终态子审批卡漏出主会话框:DB 里有 parent_msg_id IS NULL 的审批卡行,
            // 它们在 server 实际 parent 非空(子 agent 事件),只是 local DB 因
            // _mergeHistory 旧实现(loadedIds 用 filtered 后 id)被 _fromRow 脏版本
            // 回写形成自维持脏数据循环。本次清掉残留行 + 修 _mergeHistory
            // (chat_provider loadedIds 改用 loaded 全部 id)打破循环。
            // 不清 parent 非空行:那些是 loadMoreHistory putMessages(remoteRaw)
            // 写入的合法 server 数据,_filterDisplayable 能正确挡掉。
            await customStatement(
                "DELETE FROM messages WHERE parent_msg_id IS NULL AND "
                "json_extract(content, '\$.msg_type') IN "
                "('permission_card', 'question_card')");
          }
        },
      );

  /// DB 文件路径:ApplicationDocumentsDirectory + sha256(uid)[:16] 命名。
  static Future<File> _dbFile(String uid) async {
    final dir = await getApplicationDocumentsDirectory();
    final name = LocalMessageKey.dbFileName(uid: uid);
    return File(p.join(dir.path, name));
  }

  /// 打开加密 DB。
  ///
  /// 失败处理:
  /// - 第一次失败:备份原 DB 文件(`.corrupted.<时间戳>`)+ 清理密钥 + 重新生成 + 重试
  /// - 第二次失败:抛 [LocalDatabaseOpenException],让调用方决定如何呈现
  ///
  /// 仅 SQLCipher 解密失败才走清理路径;其他异常(磁盘满 / native lib 加载失败)
  /// 直接上抛,避免误删合法数据。
  static Future<LocalMessageDatabase> open({required String uid}) async {
    final file = await _dbFile(uid);

    try {
      return await _openWithKey(file, uid);
    } catch (e) {
      debugPrint('[localdb] 第一次 open 失败 uid=$uid: $e');
      // 备份原文件(留诊断副本,DB 文件不大)
      await _backupCorruptedFile(file);
      // 视为密钥/文件损坏:清密钥重新生成
      await LocalMessageKey.clear(uid: uid);
      try {
        return await _openWithKey(file, uid);
      } catch (e2) {
        debugPrint('[localdb] 二次 open 失败 uid=$uid: $e2');
        throw LocalDatabaseOpenException(
          '本地 DB 二次 open 失败,可能需要从服务器重新同步',
          original: e2,
        );
      }
    }
  }

  static Future<void> _backupCorruptedFile(File file) async {
    try {
      if (await file.exists()) {
        final ts = DateTime.now().millisecondsSinceEpoch;
        await file.rename('${file.path}.corrupted.$ts');
      }
    } catch (e) {
      debugPrint('[localdb] 备份失败(忽略): $e');
    }
  }

  static Future<LocalMessageDatabase> _openWithKey(File file, String uid) async {
    final key = await LocalMessageKey.getOrCreate(uid: uid);
    final keyHex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');

    final db = LocalMessageDatabase(
      NativeDatabase.createInBackground(
        file,
        setup: (rawDb) {
          rawDb.execute("PRAGMA key = \"x'$keyHex'\";");
          rawDb.execute('PRAGMA cipher_compatibility = 4;');
          validateSqlCipher(rawDb);
        },
      ),
    );
    await db.customSelect('SELECT 1').get();
    return db;
  }

  @visibleForTesting
  static void validateSqlCipher(CommonDatabase db) {
    final result = db.select('PRAGMA cipher_version;');
    final hasCipher = result.isNotEmpty &&
        result.first.values.any((v) => v.toString().isNotEmpty);
    if (!hasCipher) {
      throw StateError(
        'SQLCipher 未生效:PRAGMA cipher_version 返回空结果集,'
        'native 库可能是普通 SQLite 而非 SQLCipher 编译版。',
      );
    }
  }
}

/// 本地 DB open 失败(二次重试后),需调用方决策如何呈现给用户。
class LocalDatabaseOpenException implements Exception {
  final String message;
  final Object? original;

  LocalDatabaseOpenException(this.message, {this.original});

  @override
  String toString() =>
      'LocalDatabaseOpenException: $message (original: $original)';
}

/// 业务接口:基于 drift 的 LocalMessageStore CRUD 实现。
/// 转换层在 MessagesRow ↔ ChatMessage 之间。
extension LocalMessageStoreImpl on LocalMessageDatabase {
  /// 单条 upsert(id 冲突时整体替换)。
  Future<void> putMessage(ChatMessage msg) async {
    // 空聚合卡中间态(generating+无 elements)不写库:重进读到会渲染空白且
    // server 拉取范围可能覆盖不到。生成中的卡由 WS 实时建卡/填充,不依赖缓存。
    if (_isEmptyAggregateCard(msg)) return;
    await into(messages).insertOnConflictUpdate(_toRow(msg));
  }

  /// 批量插入(原子事务,insertOrReplace 语义同 putMessage)。
  Future<void> putMessages(Iterable<ChatMessage> msgs) async {
    final valid = msgs.where((m) => !_isEmptyAggregateCard(m)).toList();
    if (valid.isEmpty) return;
    await batch((b) => b.insertAll(
          messages,
          valid.map(_toRow).toList(),
          mode: InsertMode.insertOrReplace,
        ));
  }

  /// 拉取会话消息(newest first),支持 before/after 游标分页。
  Future<List<ChatMessage>> getMessages({
    required String conversationId,
    int limit = 100,
    DateTime? before,
    DateTime? after,
  }) async {
    final query = select(messages)
      ..where((t) => t.conversationId.equals(conversationId))
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
      ..limit(limit);
    if (before != null) {
      query.where(
          (t) => t.createdAt.isSmallerThanValue(before.millisecondsSinceEpoch));
    }
    if (after != null) {
      query.where(
          (t) => t.createdAt.isBiggerThanValue(after.millisecondsSinceEpoch));
    }
    final rows = await query.get();

    // _fromRow 失败跳过,避免拖垮整批(满足 abstract silently fallback 契约)
    final results = <ChatMessage>[];
    var failures = 0;
    for (final row in rows) {
      try {
        results.add(_fromRow(row));
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) {
      debugPrint('[localdb] getMessages: $failures/${rows.length} rows parse failed');
    }
    return results;
  }

  /// 聚合卡是否为空中间态(generating + elements 空/缺失)。是则不入库:
  /// 生成中的聚合卡靠 WS 实时建卡/填充,DB 缓存空快照会在重进时渲染空白卡
  /// (server 拉取范围可能覆盖不到,见 chat_provider._isEmptyAggregateCard)。
  bool _isEmptyAggregateCard(ChatMessage m) {
    if (MsgTypeX.fromString(m.content['msg_type'] as String?) !=
        MsgType.aggregateCard) {
      return false;
    }
    final data = m.content['data'];
    if (data is! Map) return false;
    if (data['state'] == 'done') return false;
    final raw = data['elements'];
    if (raw is! List) return true;
    return raw.isEmpty;
  }

  /// ChatMessage → MessagesCompanion(写库)。
  /// 不写 senderRole(schema 没这列);isRead 是 client-only 状态不持久化。
  MessagesCompanion _toRow(ChatMessage m) => MessagesCompanion(
        id: Value(m.id),
        conversationId: Value(m.conversationId),
        senderType: Value(m.senderType),
        senderId: Value(m.senderId),
        senderName: m.senderName != null ? Value(m.senderName) : Value.absent(),
        senderAvatarUrl: m.senderAvatarUrl != null ? Value(m.senderAvatarUrl) : Value.absent(),
        content: Value(jsonEncode(m.content)),
        createdAt: Value(m.createdAt.millisecondsSinceEpoch),
        status: Value(m.status.name),
        isRecalled: Value(m.isRecalled),
        recalledByName: Value(m.recalledByName ?? ''),
        parentMsgId: m.parentMsgId != null && m.parentMsgId!.isNotEmpty ? Value(m.parentMsgId) : Value.absent(),
        rootMsgId: m.rootMsgId != null && m.rootMsgId!.isNotEmpty ? Value(m.rootMsgId) : Value.absent(),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      );

  /// MessagesRow → ChatMessage(读库)。
  /// isRead 恒 true(从持久层恢复的消息视为已读;只读路径,UI 不写)。
  /// senderRole 不读(schema 没这列,留在 model 上为 nullable)。
  /// quote 从 content.data.quote 解析(跟 ChatMessage.fromJson 对称),
  /// 让 DB eager 呈现的消息也能立即显示引用块(不依赖 server 拉取覆盖时序)。
  ChatMessage _fromRow(Message row) {
    final content = jsonDecode(row.content) as Map<String, dynamic>;
    final msg = ChatMessage(
      id: row.id,
      conversationId: row.conversationId,
      senderType: row.senderType,
      senderId: row.senderId,
      senderName: row.senderName,
      senderAvatarUrl: row.senderAvatarUrl,
      content: content,
      quote: parseQuote(content),
      isRead: true,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
      status: _parseStatus(row.status),
      isRecalled: row.isRecalled,
      // 空串视为 null,还原 model nullable 语义
      recalledByName: row.recalledByName.isEmpty ? null : row.recalledByName,
      parentMsgId: row.parentMsgId,
      rootMsgId: row.rootMsgId,
    );
    return msg;
  }

  /// 防御性解析 status,未知值兜底为 sent(满足 abstract silently fallback 契约)。
  MessageStatus _parseStatus(String s) {
    return MessageStatus.values.asNameMap()[s] ?? MessageStatus.sent;
  }

  /// 修改消息 content(审批决策后 / 编辑场景)。
  Future<void> updateContent(String msgId, Map<String, dynamic> content) async {
    await (messages.update()..where((t) => t.id.equals(msgId))).write(
      MessagesCompanion(
        content: Value(jsonEncode(content)),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// 切撤回态:isRecalled=true + recalledByName 占位。
  Future<void> markRecalled(String msgId, {String recalledByName = ''}) async {
    await (messages.update()..where((t) => t.id.equals(msgId))).write(
      MessagesCompanion(
        isRecalled: const Value(true),
        recalledByName: Value(recalledByName),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// 物理删除消息(hide 场景)。
  Future<void> deleteMessage(String msgId) async {
    await (messages.delete()..where((t) => t.id.equals(msgId))).go();
  }

  /// 切 status 列(sending/sent/failed)。
  Future<void> updateStatus(String msgId, MessageStatus status) async {
    await (messages.update()..where((t) => t.id.equals(msgId))).write(
      MessagesCompanion(
        status: Value(status.name),
        updatedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
  }

  /// 单事务原子:删 localId 行 + 用新 serverId + serverCreatedAt + sent 状态重新插入。
  /// 中途任何失败都会回滚,保证不会留下「localId 已删 / serverId 未插」的中间态。
  Future<void> replaceLocalWithServer(
      String localId, String serverId, DateTime serverCreatedAt) async {
    await transaction(() async {
      final old = await (select(messages)..where((t) => t.id.equals(localId)))
          .getSingleOrNull();
      if (old == null) return;
      await (messages.delete()..where((t) => t.id.equals(localId))).go();
      await into(messages).insertOnConflictUpdate(old.copyWith(
        id: serverId,
        createdAt: serverCreatedAt.millisecondsSinceEpoch,
        status: MessageStatus.sent.name,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
    });
  }

  /// 会话最新消息的 created_at(列表排序用),空会话返回 null。
  Future<DateTime?> getLastMessageAt(String conversationId) async {
    final row = await (select(messages)
          ..where((t) => t.conversationId.equals(conversationId))
          ..orderBy([(t) => OrderingTerm.desc(t.createdAt)])
          ..limit(1))
        .getSingleOrNull();
    if (row == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(row.createdAt);
  }

  /// 全局 seq cursor(增量同步用),未设置返回 null。
  Future<int?> getGlobalLastSeq() async {
    final row = await (select(kvs)..where((t) => t.key.equals('global_last_seq')))
        .getSingleOrNull();
    if (row == null) return null;
    return int.tryParse(row.value);
  }

  /// 更新全局 seq cursor(单调 max 语义)。
  ///
  /// 乱序到达(例如 fire-and-forget 并发 dispatch)时,直接 upsert 会用旧值
  /// 覆盖新值导致 cursor 倒退 → Resume 用旧 cursor 真实丢消息。这里在事务内
  /// read-compare-write,保证 cursor 只增不减。
  Future<void> setGlobalLastSeq(int seq) async {
    await transaction(() async {
      final existing = await getGlobalLastSeq();
      final next = (existing == null || seq > existing) ? seq : existing;
      await into(kvs).insertOnConflictUpdate(
        KvsCompanion(
          key: const Value('global_last_seq'),
          value: Value(next.toString()),
        ),
      );
    });
  }

  /// KVS:conv_meta 命名空间 {ownerId}:{convId} → json({type, title})
  @override
  Future<void> putConversationMeta(String ownerId, String convId, String type, String? title) async {
    await into(kvs).insertOnConflictUpdate(KvsCompanion(
      key: Value('conv_meta:$ownerId:$convId'),
      value: Value(jsonEncode({'type': type, 'title': title})),
    ));
  }

  @override
  Future<({String type, String? title})?> getConversationMeta(String ownerId, String convId) async {
    final row = await (select(kvs)..where((t) => t.key.equals('conv_meta:$ownerId:$convId')))
        .getSingleOrNull();
    if (row == null) return null;
    try {
      final data = jsonDecode(row.value) as Map<String, dynamic>;
      return (type: data['type'] as String, title: data['title'] as String?);
    } catch (_) {
      return null;
    }
  }

  /// 清空指定会话的所有消息 + 元数据(退出会话 / 注销场景)。
  /// 用 transaction 包裹,任一失败回滚,避免留中间态。
  Future<void> clearConversation(String conversationId) async {
    await transaction(() async {
      await (messages.delete()..where((t) => t.conversationId.equals(conversationId))).go();
      await (conversationMetas.delete()..where((t) => t.conversationId.equals(conversationId))).go();
    });
  }

  /// 清空整个本地 DB(切换账号 / 注销场景)。
  /// 用 transaction 包裹,任一失败回滚,避免留中间态。
  Future<void> clearAll() async {
    await transaction(() async {
      await messages.delete().go();
      await conversationMetas.delete().go();
      await kvs.delete().go();
      // F5: 加 4 张列表缓存表
      await conversations.delete().go();
      await agents.delete().go();
      await friends.delete().go();
      await friendRequests.delete().go();
    });
  }

  // === F5: 列表缓存(4 张表)==

  Future<void> putConversations(String ownerId, Iterable<model.Conversation> items) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      await (delete(conversations)..where((t) => t.ownerId.equals(ownerId))).go();
      if (items.isNotEmpty) {
        await batch((b) => b.insertAll(
              conversations,
              items.map((c) => ConversationsCompanion(
                    id: Value(c.id),
                    ownerId: Value(ownerId),
                    data: Value(jsonEncode(c.toJson())),
                    updatedAt: Value(now),
                  )),
              mode: InsertMode.insertOrReplace,
            ));
      }
    });
  }

  Future<List<model.Conversation>> getConversations(String ownerId) async {
    final rows = await (select(conversations)..where((t) => t.ownerId.equals(ownerId))).get();
    final results = <model.Conversation>[];
    var failures = 0;
    for (final row in rows) {
      try {
        results.add(model.Conversation.fromJson(jsonDecode(row.data) as Map<String, dynamic>));
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) {
      debugPrint('[localdb] getConversations: $failures/${rows.length} rows parse failed');
    }
    return results;
  }

  Future<void> putConversation(String ownerId, model.Conversation item) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await into(conversations).insertOnConflictUpdate(ConversationsCompanion(
      id: Value(item.id),
      ownerId: Value(ownerId),
      data: Value(jsonEncode(item.toJson())),
      updatedAt: Value(now),
    ));
  }

  Future<model.Conversation?> getConversation(String ownerId, String convId) async {
    final row = await (select(conversations)
          ..where((t) => t.ownerId.equals(ownerId) & t.id.equals(convId)))
        .getSingleOrNull();
    if (row == null) return null;
    try {
      return model.Conversation.fromJson(jsonDecode(row.data) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[localdb] getConversation _fromRow fail for id=$convId: $e');
      return null;
    }
  }

  Future<void> putAgents(String ownerId, Iterable<model.Agent> items) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      await (delete(agents)..where((t) => t.ownerId.equals(ownerId))).go();
      if (items.isNotEmpty) {
        await batch((b) => b.insertAll(
              agents,
              items.map((a) => AgentsCompanion(
                    id: Value(a.id),
                    ownerId: Value(ownerId),
                    data: Value(jsonEncode(a.toJson())),
                    updatedAt: Value(now),
                  )),
              mode: InsertMode.insertOrReplace,
            ));
      }
    });
  }

  Future<List<model.Agent>> getAgents(String ownerId) async {
    final rows = await (select(agents)..where((t) => t.ownerId.equals(ownerId))).get();
    final results = <model.Agent>[];
    var failures = 0;
    for (final row in rows) {
      try {
        results.add(model.Agent.fromJson(jsonDecode(row.data) as Map<String, dynamic>));
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) {
      debugPrint('[localdb] getAgents: $failures/${rows.length} rows parse failed');
    }
    return results;
  }

  Future<void> putAgent(String ownerId, model.Agent item) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await into(agents).insertOnConflictUpdate(AgentsCompanion(
      id: Value(item.id),
      ownerId: Value(ownerId),
      data: Value(jsonEncode(item.toJson())),
      updatedAt: Value(now),
    ));
  }

  Future<void> putFriends(String ownerId, Iterable<UserSummary> items) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await transaction(() async {
      await (delete(friends)..where((t) => t.ownerId.equals(ownerId))).go();
      if (items.isNotEmpty) {
        await batch((b) => b.insertAll(
              friends,
              items.map((f) => FriendsCompanion(
                    // 用 username 作主键(UserSummary 不持 user_id)
                    id: Value(f.username),
                    ownerId: Value(ownerId),
                    data: Value(jsonEncode(f.toJson())),
                    updatedAt: Value(now),
                  )),
              mode: InsertMode.insertOrReplace,
            ));
      }
    });
  }

  Future<List<UserSummary>> getFriends(String ownerId) async {
    final rows = await (select(friends)..where((t) => t.ownerId.equals(ownerId))).get();
    final results = <UserSummary>[];
    var failures = 0;
    for (final row in rows) {
      try {
        results.add(UserSummary.fromJson(jsonDecode(row.data) as Map<String, dynamic>));
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) {
      debugPrint('[localdb] getFriends: $failures/${rows.length} rows parse failed');
    }
    return results;
  }

  Future<void> putFriendRequests(String ownerId, String direction, Iterable<model.FriendRequest> items) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    // 用 transaction 包裹,任一失败回滚,避免「旧数据已删 + 新数据没写」中间态。
    // 与同文件 clearAll / clearLists / replaceLocalWithServer 多步写规约一致。
    await transaction(() async {
      // 先删该 direction 旧数据(完全覆盖语义)
      await (friendRequests.delete()
            ..where((t) => t.ownerId.equals(ownerId))
            ..where((t) => t.direction.equals(direction)))
          .go();
      await batch((b) => b.insertAll(
            friendRequests,
            items.map((r) => FriendRequestsCompanion(
                  id: Value(r.id),
                  ownerId: Value(ownerId),
                  direction: Value(direction),
                  data: Value(jsonEncode(r.toJson())),
                  updatedAt: Value(now),
                )),
            mode: InsertMode.insertOrReplace,
          ));
    });
  }

  Future<List<model.FriendRequest>> getFriendRequests(String ownerId, String direction) async {
    final rows = await (select(friendRequests)
          ..where((t) => t.ownerId.equals(ownerId))
          ..where((t) => t.direction.equals(direction)))
        .get();
    final results = <model.FriendRequest>[];
    var failures = 0;
    for (final row in rows) {
      try {
        results.add(model.FriendRequest.fromJson(jsonDecode(row.data) as Map<String, dynamic>));
      } catch (_) {
        failures++;
      }
    }
    if (failures > 0) {
      debugPrint('[localdb] getFriendRequests: $failures/${rows.length} rows parse failed');
    }
    return results;
  }

  Future<void> clearLists(String ownerId) async {
    await transaction(() async {
      await (conversations.delete()..where((t) => t.ownerId.equals(ownerId))).go();
      await (agents.delete()..where((t) => t.ownerId.equals(ownerId))).go();
      await (friends.delete()..where((t) => t.ownerId.equals(ownerId))).go();
      await (friendRequests.delete()..where((t) => t.ownerId.equals(ownerId))).go();
    });
  }
}
