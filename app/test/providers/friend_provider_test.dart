import 'package:wanling_core/models/friendship.dart';
import 'package:wanling_core/models/user_summary.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart' show wsProvider;
import 'package:app/providers/friend_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_local_message_store.dart';
import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;
  late FakeWS ws;

  setUp(() {
    api = MockApi();
    ws = FakeWS();
    // 默认 stub：空三列表（多数 case 在此基础上 override）
    when(() => api.listFriends()).thenAnswer((_) async => []);
    when(() => api.listIncomingFriendRequests()).thenAnswer((_) async => []);
    when(() => api.listOutgoingFriendRequests()).thenAnswer((_) async => []);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  UserSummary user(String username, {String nickname = '', String avatar = ''}) =>
      UserSummary(
        username: username,
        nickname: nickname,
        avatarUrl: avatar,
      );

  FriendRequest fr(
    String id,
    UserSummary u, {
    FriendshipStatus status = FriendshipStatus.pending,
    DateTime? createdAt,
  }) =>
      FriendRequest(
        id: id,
        status: status,
        createdAt: createdAt ?? DateTime(2026, 7, 1, 10),
        user: u,
      );

  group('load', () {
    test('拉取三列表并解析', () async {
      when(() => api.listFriends())
          .thenAnswer((_) async => [user('alice', nickname: 'Alice')]);
      when(() => api.listIncomingFriendRequests())
          .thenAnswer((_) async => [fr('r1', user('bob'))]);
      when(() => api.listOutgoingFriendRequests()).thenAnswer(
          (_) async => [fr('r2', user('carol', nickname: 'Carol'))]);

      final container = makeContainer();
      // read 触发构造 → autoload=true → load() 启动
      container.read(friendListProvider);
      // 等 load 完成（Future.wait + microtask）
      await Future.delayed(Duration.zero);

      final state = container.read(friendListProvider);
      expect(state.friends.length, 1);
      expect(state.friends.first.username, 'alice');
      expect(state.incoming.length, 1);
      expect(state.incoming.first.id, 'r1');
      expect(state.incoming.first.user.username, 'bob');
      expect(state.outgoing.length, 1);
      expect(state.outgoing.first.id, 'r2');
      expect(state.outgoing.first.user.username, 'carol');
      expect(state.incomingCount, 1);
      expect(state.totalUnread, 1);
    });

    test('拉取失败保留空状态不抛', () async {
      when(() => api.listFriends())
          .thenThrow(Exception('network error'));

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      final state = container.read(friendListProvider);
      expect(state.friends, isEmpty);
      expect(state.incoming, isEmpty);
      expect(state.outgoing, isEmpty);
    });
  });

  group('sendRequest', () {
    test('成功加到 outgoing', () async {
      when(() => api.createFriendRequest('dave')).thenAnswer((_) async =>
          fr('r3', user('dave', nickname: 'Dave')));

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      final notifier = container.read(friendListProvider.notifier);
      final id = await notifier.sendRequest('dave');

      expect(id, 'r3');
      final state = container.read(friendListProvider);
      expect(state.outgoing.length, 1);
      expect(state.outgoing.first.id, 'r3');
      expect(state.outgoing.first.user.username, 'dave');
      expect(state.outgoing.first.user.nickname, 'Dave');
      expect(state.outgoing.first.status, FriendshipStatus.pending);
    });

    test('server 409 抛异常给 UI（state 不变）', () async {
      when(() => api.createFriendRequest('alice'))
          .thenThrow(Exception('already friend'));

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      final notifier = container.read(friendListProvider.notifier);
      // sendRequest 返回 Future，expect 直接对 Future 校验
      await expectLater(notifier.sendRequest('alice'), throwsA(anything));

      final state = container.read(friendListProvider);
      expect(state.outgoing, isEmpty);
    });
  });

  group('accept', () {
    test('incoming 移到 friends', () async {
      when(() => api.listIncomingFriendRequests())
          .thenAnswer((_) async => [fr('r1', user('bob'))]);
      when(() => api.acceptFriendRequest('r1'))
          .thenAnswer((_) async {});

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      expect(container.read(friendListProvider).incoming.length, 1);

      final notifier = container.read(friendListProvider.notifier);
      await notifier.accept('r1');

      final state = container.read(friendListProvider);
      expect(state.incoming, isEmpty);
      expect(state.friends.length, 1);
      expect(state.friends.first.username, 'bob');
    });

    test('accept 未知 requestId 状态不变', () async {
      when(() => api.acceptFriendRequest('unknown'))
          .thenAnswer((_) async {});

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      final notifier = container.read(friendListProvider.notifier);
      await notifier.accept('unknown');

      final state = container.read(friendListProvider);
      expect(state.incoming, isEmpty);
      expect(state.friends, isEmpty);
    });
  });

  group('reject', () {
    test('incoming 移除', () async {
      when(() => api.listIncomingFriendRequests())
          .thenAnswer((_) async => [fr('r1', user('bob'))]);
      when(() => api.rejectFriendRequest('r1'))
          .thenAnswer((_) async {});

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      final notifier = container.read(friendListProvider.notifier);
      await notifier.reject('r1');

      final state = container.read(friendListProvider);
      expect(state.incoming, isEmpty);
      expect(state.friends, isEmpty);
    });
  });

  group('removeFriend', () {
    test('friends 移除', () async {
      when(() => api.listFriends())
          .thenAnswer((_) async => [user('alice')]);
      when(() => api.removeFriend('alice'))
          .thenAnswer((_) async {});

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      expect(container.read(friendListProvider).friends.length, 1);

      final notifier = container.read(friendListProvider.notifier);
      await notifier.removeFriend('alice');

      expect(container.read(friendListProvider).friends, isEmpty);
    });

    test('只移除目标 username 其他保留', () async {
      when(() => api.listFriends())
          .thenAnswer((_) async => [user('alice'), user('bob')]);
      when(() => api.removeFriend('alice'))
          .thenAnswer((_) async {});

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      final notifier = container.read(friendListProvider.notifier);
      await notifier.removeFriend('alice');

      final friends = container.read(friendListProvider).friends;
      expect(friends.length, 1);
      expect(friends.first.username, 'bob');
    });
  });

  group('_onFriendEvent (WS)', () {
    test('FRIEND_REQUEST_RECEIVED 加到 incoming', () async {
      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      ws.emitFriend(WSMessage(
        op: 0,
        t: 'FRIEND_REQUEST_RECEIVED',
        s: 1,
        d: {
          'request_id': 'ws-r1',
          'from_user_summary': {
            'username': 'eve',
            'nickname': 'Eve',
            'avatar_url': '',
          },
          'created_at': '2026-07-01T12:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      final state = container.read(friendListProvider);
      expect(state.incoming.length, 1);
      expect(state.incoming.first.id, 'ws-r1');
      expect(state.incoming.first.user.username, 'eve');
      expect(state.incoming.first.user.nickname, 'Eve');
      // 新请求在最前
      expect(state.incomingCount, 1);
    });

    test('FRIEND_REQUEST_RECEIVED 兼容老字段 from_user', () async {
      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      ws.emitFriend(WSMessage(
        op: 0,
        t: 'FRIEND_REQUEST_RECEIVED',
        s: 1,
        d: {
          'request_id': 'ws-r2',
          'from_user': {
            'username': 'frank',
            'nickname': '',
            'avatar_url': '',
          },
          'created_at': '2026-07-01T12:00:00Z',
        },
      ));
      await Future.delayed(Duration.zero);

      expect(container.read(friendListProvider).incoming.first.user.username,
          'frank');
    });

    test('FRIEND_REQUEST_RECEIVED 同 request_id 去重', () async {
      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      final payload = {
        'request_id': 'dup-r1',
        'from_user_summary': {
          'username': 'eve',
          'nickname': '',
          'avatar_url': '',
        },
        'created_at': '2026-07-01T12:00:00Z',
      };
      ws.emitFriend(
          WSMessage(op: 0, t: 'FRIEND_REQUEST_RECEIVED', s: 1, d: payload));
      await Future.delayed(Duration.zero);
      ws.emitFriend(
          WSMessage(op: 0, t: 'FRIEND_REQUEST_RECEIVED', s: 2, d: payload));
      await Future.delayed(Duration.zero);

      expect(container.read(friendListProvider).incoming.length, 1);
    });

    test('FRIEND_REQUEST_DECIDED accepted → reload', () async {
      // outgoing 初始有 1 条；reload 后 outgoing 清空
      var outgoingCallCount = 0;
      when(() => api.listOutgoingFriendRequests()).thenAnswer((_) async {
        outgoingCallCount++;
        if (outgoingCallCount >= 2) return [];
        return [fr('r-out', user('bob'))];
      });
      // listFriends 第 1 次（初始 load）返空；第 2 次（DECIDED accepted reload）
      // 返带 bob（被接受后变成 friend）
      var friendsCallCount = 0;
      when(() => api.listFriends()).thenAnswer((_) async {
        friendsCallCount++;
        if (friendsCallCount >= 2) {
          return [user('bob')];
        }
        return [];
      });

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);
      expect(container.read(friendListProvider).outgoing.length, 1);

      ws.emitFriend(WSMessage(
        op: 0,
        t: 'FRIEND_REQUEST_DECIDED',
        s: 2,
        d: {
          'request_id': 'r-out',
          'decision': 'accepted',
          'by_user': 'bob-id',
        },
      ));
      // 等 reload 完成
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      final state = container.read(friendListProvider);
      expect(state.outgoing, isEmpty);
      expect(state.friends.length, 1);
      expect(state.friends.first.username, 'bob');
    });

    test('FRIEND_REQUEST_DECIDED rejected → outgoing 移除 不 reload', () async {
      when(() => api.listOutgoingFriendRequests())
          .thenAnswer((_) async => [fr('r-out', user('bob'))]);

      // 用 registerFallbackValue + 计数器追踪 listFriends 调用次数
      var listFriendsCalls = 0;
      when(() => api.listFriends()).thenAnswer((_) async {
        listFriendsCalls++;
        return [];
      });

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);
      // 初始 load 后 listFriends 应被调 1 次
      expect(listFriendsCalls, 1);

      ws.emitFriend(WSMessage(
        op: 0,
        t: 'FRIEND_REQUEST_DECIDED',
        s: 2,
        d: {
          'request_id': 'r-out',
          'decision': 'rejected',
          'by_user': 'bob-id',
        },
      ));
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(container.read(friendListProvider).outgoing, isEmpty);
      // rejected 不 reload，listFriends 调用次数不应增加
      expect(listFriendsCalls, 1);
    });

    test('FRIEND_REQUEST_DECIDED canceled → outgoing 移除', () async {
      when(() => api.listOutgoingFriendRequests())
          .thenAnswer((_) async => [fr('r-out', user('bob'))]);

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      ws.emitFriend(WSMessage(
        op: 0,
        t: 'FRIEND_REQUEST_DECIDED',
        s: 2,
        d: {
          'request_id': 'r-out',
          'decision': 'canceled',
          'by_user': 'bob-id',
        },
      ));
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      expect(container.read(friendListProvider).outgoing, isEmpty);
    });

    test('FRIEND_REMOVED → reload', () async {
      // 初始 friends 2 个；reload 后只剩 alice（被删的是 bob）
      var friendsCallCount = 0;
      when(() => api.listFriends()).thenAnswer((_) async {
        friendsCallCount++;
        if (friendsCallCount >= 2) {
          return [user('alice')];
        }
        return [user('alice'), user('bob')];
      });

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);
      expect(container.read(friendListProvider).friends.length, 2);

      ws.emitFriend(WSMessage(
        op: 0,
        t: 'FRIEND_REMOVED',
        s: 3,
        d: {
          'by_user': 'bob-id',
          'friend_id': 'me-id',
        },
      ));
      await Future.delayed(Duration.zero);
      await Future.delayed(Duration.zero);

      final friends = container.read(friendListProvider).friends;
      expect(friends.length, 1);
      expect(friends.first.username, 'alice');
    });

    test('未知事件 t 静默忽略', () async {
      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      ws.emitFriend(WSMessage(
        op: 0,
        t: 'UNKNOWN_FRIEND_EVENT',
        s: 99,
        d: {'foo': 'bar'},
      ));
      await Future.delayed(Duration.zero);

      // 状态不变
      final state = container.read(friendListProvider);
      expect(state.friends, isEmpty);
      expect(state.incoming, isEmpty);
      expect(state.outgoing, isEmpty);
    });

    test('d 为 null 静默忽略', () async {
      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      ws.emitFriend(WSMessage(op: 0, t: 'FRIEND_REQUEST_RECEIVED', s: 1));
      await Future.delayed(Duration.zero);

      expect(container.read(friendListProvider).incoming, isEmpty);
    });
  });

  group('friendIncomingCountProvider', () {
    test('反映 incoming 数量', () async {
      when(() => api.listIncomingFriendRequests()).thenAnswer((_) async => [
            fr('r1', user('bob')),
            fr('r2', user('carol'),
                createdAt: DateTime(2026, 7, 1, 11)),
          ]);

      final container = makeContainer();
      container.read(friendListProvider);
      await Future.delayed(Duration.zero);

      expect(container.read(friendIncomingCountProvider), 2);
    });
  });

  test('UserSummary.displayName 优先 nickname', () {
    final u = user('alice', nickname: 'Alice');
    expect(u.displayName, 'Alice');
    final u2 = user('bob');
    expect(u2.displayName, 'bob');
  });

  group('F5: friendListProvider cache-first', () {
    late MockApi api;
    late FakeWS ws;
    late FakeLocalMessageStore store;

    setUp(() {
      api = MockApi();
      ws = FakeWS();
      store = FakeLocalMessageStore();
      // 默认 stub：空三列表(允许 F5 新测试覆盖)
      when(() => api.listFriends()).thenAnswer((_) async => []);
      when(() => api.listIncomingFriendRequests()).thenAnswer((_) async => []);
      when(() => api.listOutgoingFriendRequests()).thenAnswer((_) async => []);
    });

    test('load 先返 cached 三列表, 后台 API 刷新', () async {
      // store 有 cached
      await store.putFriends('u1', [
        UserSummary(username: 'old_friend', nickname: 'Old', avatarUrl: ''),
      ]);
      await store.putFriendRequests('u1', 'incoming', [
        FriendRequest(
          id: 'r1',
          status: FriendshipStatus.pending,
          createdAt: DateTime.utc(2026, 7, 1),
          user: UserSummary(
              username: 'req1', nickname: 'R1', avatarUrl: ''),
        ),
      ]);

      // API 返 fresh(注意:三列表都返非空才覆盖,这里让 friends/incoming 都被
      // server 覆盖,outgoing 留空但 local 也空 → 不触发空保护)
      when(() => api.listFriends()).thenAnswer((_) async => [
            UserSummary(username: 'new_friend', nickname: 'New', avatarUrl: ''),
          ]);
      when(() => api.listIncomingFriendRequests()).thenAnswer((_) async => []);
      when(() => api.listOutgoingFriendRequests()).thenAnswer((_) async => []);

      final notifier = FriendListNotifier(api, ws,
          store: store, ownerId: 'u1');
      await Future.delayed(const Duration(milliseconds: 50));

      // fresh 覆盖
      expect(notifier.state.friends.first.username, 'new_friend');
      expect(notifier.state.incoming, isEmpty);
    });

    test('WS FRIEND_REQUEST_RECEIVED 落库 store.putFriendRequests', () async {
      final notifier = FriendListNotifier(api, ws,
          store: store, ownerId: 'u1');
      await Future.delayed(const Duration(milliseconds: 50));

      // 注意: FriendListNotifier 订阅的是 ws.friendUpdates 流,
      // FakeWS 的 emitFriend 才会推到该流(emit 是 messages 流)。
      ws.emitFriend(WSMessage(
        op: 0,
        t: 'FRIEND_REQUEST_RECEIVED',
        d: {
          'request_id': 'r1',
          'from_user_summary': {
            'username': 'bob',
            'nickname': 'Bob',
            'avatar_url': '',
          },
          'created_at': DateTime.utc(2026, 7, 5).toIso8601String(),
        },
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // state incoming 也 +1(本地同步)
      expect(notifier.state.incoming.length, 1);
      expect(notifier.state.incoming.first.id, 'r1');
      // store incoming 有 r1
      final stored = await store.getFriendRequests('u1', 'incoming');
      expect(stored.length, 1);
      expect(stored.first.id, 'r1');
    });

    test('WS FRIEND_REQUEST_DECIDED 移除 outgoing + 落库', () async {
      // outgoing 列表 cached 有 r1
      await store.putFriendRequests('u1', 'outgoing', [
        FriendRequest(
          id: 'r1',
          status: FriendshipStatus.pending,
          createdAt: DateTime.utc(2026, 7, 1),
          user: UserSummary(username: 'bob', nickname: 'Bob', avatarUrl: ''),
        ),
      ]);

      final notifier = FriendListNotifier(api, ws,
          store: store, ownerId: 'u1');
      await Future.delayed(const Duration(milliseconds: 50));

      // DECIDED rejected → 直接走 outgoing 落库分支(不 reload)
      ws.emitFriend(WSMessage(
        op: 0,
        t: 'FRIEND_REQUEST_DECIDED',
        d: {'request_id': 'r1', 'decision': 'rejected'},
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // state outgoing 已移除
      expect(notifier.state.outgoing, isEmpty);
      // store outgoing 也已移除
      final stored = await store.getFriendRequests('u1', 'outgoing');
      expect(stored, isEmpty);
    });
  });
}
