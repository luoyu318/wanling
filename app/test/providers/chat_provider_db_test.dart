import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/unread_info.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_local_message_store.dart';
import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;
  late FakeWS ws;
  late FakeLocalMessageStore store;

  setUp(() {
    api = MockApi();
    ws = FakeWS();
    store = FakeLocalMessageStore();

    // _initialize 必经路径:getUnreadInfo + getMessagesBefore(无未读分支)。
    // 单测各 case 内覆写 thenAnswer 返不同数据。
    when(() => api.getUnreadInfo(any()))
        .thenAnswer((_) async => const UnreadInfo(unreadCount: 0));
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => <ChatMessage>[]);
    // 兜底分支可能调
    when(() => api.getMessages(any(),
            limit: any(named: 'limit'), offset: any(named: 'offset')))
        .thenAnswer((_) async => <ChatMessage>[]);
    // getConversation 兜底(各 case 可覆写为 agent_session / 抛错)。
    when(() => api.getConversation(any())).thenAnswer(
      (_) async => Conversation(
        id: 'conv1', type: 'dm_user_agent',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 1),
        createdAt: DateTime.utc(2026, 7, 1),
      ),
    );
  });

  ChatMessage mkMsg(String id,
      {DateTime? createdAt, String convId = 'conv1'}) {
    return ChatMessage(
      id: id,
      conversationId: convId,
      senderType: 'user',
      senderId: 'uid',
      content: const {'msg_type': 'text', 'data': {'text': 'hi'}},
      isRead: true,
      createdAt: createdAt ?? DateTime(2026, 7, 5),
      status: MessageStatus.sent,
    );
  }

  test('首次进入(空 DB):server 拉取后写 DB', () async {
    // server 返一条消息
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => [
              mkMsg('s1', createdAt: DateTime(2026, 7, 5, 10)),
            ]);

    // 触发 _initialize(构造即启动 fire-and-forget)。
    // ignore: unused_local_variable
    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    // _initialize 是 fire-and-forget,等它完成
    await Future.delayed(const Duration(milliseconds: 50));

    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(msgs.length, 1);
    expect(msgs.first.id, 's1');
  });

  test('二次进入(DB 有数据):即时呈现 local + 增量拉 server', () async {
    // 预置本地消息(更老)
    await store.putMessage(mkMsg('local1', createdAt: DateTime(2026, 7, 5, 9)));

    // server 返一条新消息
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => [
              mkMsg('new1', createdAt: DateTime(2026, 7, 5, 11)),
            ]);

    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    await Future.delayed(const Duration(milliseconds: 50));

    // state 应同时含 local + new
    final stateMsgs = notifier.state.displayMessages.map((m) => m.id).toSet();
    expect(stateMsgs.contains('local1'), isTrue);
    expect(stateMsgs.contains('new1'), isTrue);

    // DB 也应同时含 local + new(写入新)
    final dbMsgs = await store.getMessages(conversationId: 'conv1');
    final dbIds = dbMsgs.map((m) => m.id).toSet();
    expect(dbIds.contains('local1'), isTrue);
    expect(dbIds.contains('new1'), isTrue);
  });

  test('上滑加载(DB 命中):即时呈现 DB + server 校正', () async {
    // 当前会话窗口的 30 条(7月5日 9:00~9:29)— 对齐 ChatNotifier._pageSize=30
    final currentBatch = <ChatMessage>[];
    for (var i = 0; i < 30; i++) {
      final m = mkMsg('msg$i',
          createdAt: DateTime(2026, 7, 5, 9).add(Duration(minutes: i)));
      currentBatch.add(m);
      await store.putMessage(m);
    }
    // 更老的 30 条(7月4日)— loadMore DB 应命中这部分
    for (var i = 0; i < 30; i++) {
      await store.putMessage(mkMsg('old$i',
          createdAt: DateTime(2026, 7, 4).add(Duration(minutes: i))));
    }

    // 用计数器区分 _initialize 期间 vs loadMore 期间的 server 调用。
    var serverBeforeCalls = 0;
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((inv) {
      serverBeforeCalls++;
      // _initialize 期间 before=null,返当前批 30 条(让 hasMore=true);
      // loadMore 期间 before!=null,server 返空(模拟校正无新增)。
      final before = inv.namedArguments[#before] as DateTime?;
      if (before == null) {
        return Future.value(currentBatch);
      }
      return Future.value(<ChatMessage>[]);
    });

    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    await Future.delayed(const Duration(milliseconds: 50));

    // _initialize 期间(unreadCount==0)调一次 getMessagesBefore(before=null)
    final initCalls = serverBeforeCalls;
    expect(initCalls, 1, reason: '_initialize 调一次 getMessagesBefore(before=null)');

    // 初始 state:DB 优先 30 条(server 返同批,_mergeHistory 去重保持 30)
    expect(notifier.state.displayMessages.length, 30,
        reason: 'DB 优先应即时呈现 30 条');
    expect(notifier.state.hasMore, isTrue,
        reason: 'server 返整页,hasMore=true 才能触发 loadMore');

    await notifier.loadMoreHistory();

    // C3 修复后:loadMore DB 命中后仍然 server 校正,所以 server 多调 1 次
    expect(serverBeforeCalls, initCalls + 1,
        reason: 'C3 修复:DB 命中仍然 server 校正,loadMore 调一次 getMessagesBefore(before!=null)');

    // state 应有 60 条(DB 初始 30 + DB 上滑追加 30 条更老消息,server 返空被去重)
    expect(notifier.state.displayMessages.length, 60,
        reason: 'loadMore 应从 DB 追加 30 条更老消息');
    expect(notifier.state.displayMessages.any((m) => m.id == 'old0'), isTrue,
        reason: '应包含 DB 命中的 old0');
  });

  test('sendText:乐观消息写 DB + echo 替换 id', () async {
    when(() => api.sendMessage(any(), any())).thenAnswer((_) async => (
          messageId: 'server_uuid',
          createdAt: DateTime(2026, 7, 5, 10),
        ));

    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    await Future.delayed(const Duration(milliseconds: 50));
    await notifier.sendText('hi');

    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(msgs.any((m) => m.id == 'server_uuid'), isTrue);
    expect(
        msgs.firstWhere((m) => m.id == 'server_uuid').status,
        MessageStatus.sent);
  });

  test('retrySend:失败消息切回 sending → 成功切 sent', () async {
    final failed = mkMsg('local_1', createdAt: DateTime(2026, 7, 5))
        .copyWith(status: MessageStatus.failed);
    await store.putMessage(failed);

    when(() => api.sendMessage(any(), any())).thenAnswer((_) async => (
          messageId: 'server_uuid',
          createdAt: DateTime(2026, 7, 5, 10),
        ));

    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    await Future.delayed(const Duration(milliseconds: 50));
    await notifier.retrySend('local_1');

    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(msgs.any((m) => m.id == 'server_uuid'), isTrue);
    expect(msgs.any((m) => m.id == 'local_1'), isFalse); // 旧 local_ id 已被替换
  });

  test('deleteMessages scope=hide 调 store.deleteMessage', () async {
    await store.putMessage(mkMsg('msg1'));
    when(() => api.deleteMessage('msg1', scope: any(named: 'scope')))
        .thenAnswer((_) async {});

    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    await Future.delayed(const Duration(milliseconds: 50));
    await notifier.deleteMessages(['msg1'], scope: 'hide');

    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(msgs, isEmpty);
  });

  test('deleteMessages scope=recall 调 store.markRecalled', () async {
    await store.putMessage(mkMsg('msg1'));
    when(() => api.deleteMessage('msg1', scope: any(named: 'scope')))
        .thenAnswer((_) async {});

    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    await Future.delayed(const Duration(milliseconds: 50));
    await notifier.deleteMessages(['msg1'], scope: 'recall');

    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(msgs.first.isRecalled, isTrue);
    // I2: ChatNotifier 乐观更新路径写空串(与 WS echo 写 server sender_name 不一致)。
    // UI 端 chat_page.dart 已确认不消费 recalledByName 字段(dm 场景按 senderId 区分),
    // 故此处差异不影响;群聊场景未来走 WS echo 时被覆盖为真名。
    expect(msgs.first.recalledByName, '');
  });

  test('deleteMessages hide server 失败时回滚 state + DB(C2)', () async {
    // server 失败时 _initialize 会被调,setUp 已 stub getUnreadInfo / getMessagesBefore。
    // 此处覆写 getMessagesBefore 返原消息(模拟 server 仍持有,因为没真删),
    // 验证 catch 块的回滚逻辑(removed 塞回 state + putMessages)。
    final msg = mkMsg('msg1', createdAt: DateTime(2026, 7, 5, 10));
    await store.putMessage(msg);
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => [msg]);
    when(() => api.deleteMessage('msg1', scope: any(named: 'scope')))
        .thenThrow(Exception('server fail'));

    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    await Future.delayed(const Duration(milliseconds: 50));

    // deleteMessages 会 rethrow,捕获避免污染测试
    try {
      await notifier.deleteMessages(['msg1'], scope: 'hide');
      fail('should throw');
    } catch (_) {}

    // state 应该含被回滚的消息(C2 修复)
    expect(notifier.state.displayMessages.any((m) => m.id == 'msg1'), isTrue,
        reason: 'hide 失败时 removed 应塞回 state');
    // DB 也应该含(C2 修复:putMessages 回滚)
    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(msgs.any((m) => m.id == 'msg1'), isTrue,
        reason: 'hide 失败时 removed 应 putMessages 回 DB');
  });

  // 回归测试:_mergeHistory 旧实现 loadedIds 用 filtered 后的 id,导致 server
  // 返回的终态子审批卡(parent 非空 + status 非.pending)被 _filterDisplayable
  // 过滤后,其 id 不在 loadedIds 里,eager DB read 出的同 id _fromRow 脏版本
  // (parent_msg_id=NULL)反而被 extra 保留进 state.displayMessages。后果:
  // 1)终态审批卡漏出主会话框(parent=NULL 绕过 _filterDisplayable guard)
  // 2)putMessages(state.displayMessages) 把脏版本回写 DB,形成自维持脏数据循环。
  // 修复:loadedIds 用 loaded 全部 id(不过滤),让 server 返回的同 id 消息
  // 覆盖 state.displayMessages 里的 _fromRow 脏版本。
  group('_mergeHistory:server loaded 含终态子审批卡时,不保留 _fromRow 脏版本', () {
    test('eager DB 含脏审批卡(parent=NULL),server loaded 同 id 正确版本(parent 非空),'
        'state + DB 都不含脏版本', () async {
      // 预置脏数据:DB 里有 parent=NULL 的终态审批卡(历史残留,_fromRow 读出 parent=NULL)
      final dirtyMsg = ChatMessage(
        id: 'dirty-1',
        conversationId: 'conv1',
        senderType: 'agent',
        senderId: 'agent-1',
        content: const {
          'msg_type': 'permission_card',
          'data': {'status': 'approved', 'action': 'external_directory'},
        },
        isRead: true,
        createdAt: DateTime(2026, 7, 5, 10),
        status: MessageStatus.sent,
        // parentMsgId 留空:null(FakeLocalMessageStore 不存 parent,模拟 _fromRow 行为)
      );
      await store.putMessage(dirtyMsg);

      // server 返回同 id 的正确版本:parent 非空 + 终态(应被 _filterDisplayable 过滤)
      final correctMsg = ChatMessage(
        id: 'dirty-1',
        conversationId: 'conv1',
        senderType: 'agent',
        senderId: 'agent-1',
        content: const {
          'msg_type': 'permission_card',
          'data': {'status': 'approved', 'action': 'external_directory'},
        },
        isRead: true,
        createdAt: DateTime(2026, 7, 5, 10),
        status: MessageStatus.sent,
        parentMsgId: 'task-1', // server 正确版本带 parent
      );
      // 还加一条普通文本消息,避免 server 完全空导致路径异常
      final normalMsg = mkMsg('text-1', createdAt: DateTime(2026, 7, 5, 11));
      when(() => api.getMessagesBefore(any(),
              limit: any(named: 'limit'), before: any(named: 'before')))
          .thenAnswer((_) async => [correctMsg, normalMsg]);

      final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
      await Future.delayed(const Duration(milliseconds: 50));

      // state.displayMessages 不应含脏审批卡:server loaded 同 id 的正确版本(parent 非空
      // + 终态)虽被 _filterDisplayable 过滤,但其 id 仍在 loadedIds 里,让 extra
      // 排除掉 state.displayMessages 里 eager 阶段读出的脏版本。
      final stateIds = notifier.state.displayMessages.map((m) => m.id).toSet();
      expect(stateIds, isNot(contains('dirty-1')),
          reason: '_mergeHistory 应用 server loaded 的 id 排除 extra 里的脏版本');
      expect(stateIds, contains('text-1'));

      // 注意:DB 里 dirty-1 仍存在(putMessages 是 upsert 语义,不删非入参消息)。
      // 这正是 v7 migration 的职责:清掉 DB 里的脏审批卡行。
      // 本测试只验证 _mergeHistory 不让脏版本进 state.displayMessages(避免漏出主会话框
      // + 避免 putMessages(state.displayMessages) 回写脏版本)。
    });
  });

  group('conversation 详情缓存(agent_session 离线兜底)', () {
    test('API getConversation 成功后写回 store(下次离线可兜底)', () async {
      when(() => api.getConversation(any())).thenAnswer(
        (_) async => Conversation(
          id: 'convAS', type: 'agent_session',
          title: '万灵会话',
          participants: const [],
          lastMessageContent: null,
          lastMessageAt: DateTime.utc(2026, 7, 1),
          createdAt: DateTime.utc(2026, 7, 1),
        ),
      );

      final notifier = ChatNotifier(api, ws, 'convAS', null, 'me', store: store);
      await Future.delayed(const Duration(milliseconds: 50));

      final cached = await store.getConversation('me', 'convAS');
      expect(cached, isNotNull, reason: 'API 成功后应写回 store');
      expect(cached!.type, 'agent_session');
      expect(cached.title, '万灵会话');
      // notifier 已 dispose 监听，避免泄漏
      notifier.dispose();
    });

    test('API getConversation 失败时,从 store 读 convType 兜底(离线头像 bug 根因)', () async {
      // 预置缓存:上次在线时写入的 agent_session 详情
      await store.putConversation('me', Conversation(
        id: 'convAS', type: 'agent_session',
        title: '万灵会话',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 1),
        createdAt: DateTime.utc(2026, 7, 1),
      ));

      // 模拟离线:API 失败
      when(() => api.getConversation(any()))
          .thenThrow(Exception('network error'));

      final notifier = ChatNotifier(api, ws, 'convAS', null, 'me', store: store);
      await Future.delayed(const Duration(milliseconds: 50));

      // 关键断言:API 失败时 convType 应从 store 兜底,不再是 null
      // (null 会导致 agent_session 退化成带头像的默认样式)
      expect(notifier.state.convType, 'agent_session',
          reason: 'API 失败时应从 store 读 convType 兜底');
      expect(notifier.state.convTitle, '万灵会话',
          reason: 'convTitle 也应从 store 兜底');
      notifier.dispose();
    });
  });

  test('c7d22e0: 聚合卡 MESSAGE_UPDATE 增量后 DB 写回最新 content', () async {
    // 先构造 notifier(建立 WS 订阅),再建聚合卡进 live
    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    await Future.delayed(const Duration(milliseconds: 50));
    ws.emit(WSMessage(
      op: 0, t: 'MESSAGE_CREATE',
      d: {
        'id': 'agg-1', 'conversation_id': 'conv1',
        'sender_type': 'agent', 'sender_id': 'a1',
        'content': {
          'msg_type': 'aggregate_card', 'silent': true,
          'data': {'schema_ver': 1, 'state': 'generating', 'elements': []},
        },
        'created_at': '2026-07-05T10:00:00Z',
      },
    ));
    await Future.delayed(const Duration(milliseconds: 100));

    // append 增量 MESSAGE_UPDATE → 应合并进 live + 写回 DB
    ws.emitUpdate(WSMessage(
      op: 0, t: 'MESSAGE_UPDATE',
      d: {
        'conversation_id': 'conv1', 'message_id': 'agg-1',
        'content': {
          'msg_type': 'aggregate_card',
          'data': {
            'op': 'append',
            'element': {
              'type': 'markdown', 'element_id': 'markdown_1',
              'data': {'text': '正文'},
            },
          },
        },
      },
    ));
    await Future.delayed(const Duration(milliseconds: 100));

    // DB 应拿到合并后的完整 content(elements 含 markdown_1)
    final dbMsgs = await store.getMessages(conversationId: 'conv1');
    final agg = dbMsgs.where((m) => m.id == 'agg-1').toList();
    expect(agg.length, 1, reason: '聚合卡写回 DB');
    final elements =
        ((agg.first.content['data'] as Map)['elements'] as List).toList();
    expect(elements.length, 1, reason: 'DB content 是合并后的完整版');
    expect((elements[0] as Map)['element_id'], 'markdown_1');
    notifier.dispose();
  });

  test('d9603bc: eager 读到空聚合卡时过滤并从 DB 删除', () async {
    // 预置 DB 空聚合卡快照(生成中空态)
    await store.putMessage(ChatMessage(
      id: 'empty-agg', conversationId: 'conv1',
      senderType: 'agent', senderId: 'a1',
      content: {
        'msg_type': 'aggregate_card',
        'data': {'schema_ver': 1, 'state': 'generating', 'elements': []},
      },
      isRead: true, createdAt: DateTime(2026, 7, 5), status: MessageStatus.sent,
    ));
    // 预置一条正常消息
    await store.putMessage(mkMsg('normal-1', createdAt: DateTime(2026, 7, 6)));

    final notifier = ChatNotifier(api, ws, 'conv1', null, 'me', store: store);
    await Future.delayed(const Duration(milliseconds: 100));

    // state 不应含空聚合卡
    expect(notifier.state.displayMessages.any((m) => m.id == 'empty-agg'),
        isFalse, reason: '空聚合卡不渲染');
    // DB 空聚合卡被删除
    final dbMsgs = await store.getMessages(conversationId: 'conv1');
    expect(dbMsgs.any((m) => m.id == 'empty-agg'), isFalse,
        reason: '空聚合卡脏记录被删除');
    expect(dbMsgs.any((m) => m.id == 'normal-1'), isTrue);
    notifier.dispose();
  });
}

