import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/friendship.dart';
import 'package:app/models/user_summary.dart';
import 'package:app/services/api_service.dart';

import '../helpers/mock_adapter.dart';

/// 构造 ApiService，MockAdapter 用 envelope 包装 data。
/// 拦截器剥 envelope 后业务层拿到 data 部分。
ApiService _api(dynamic data) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  final api = ApiService.withDio(dio);
  dio.httpClientAdapter = CapturingMockAdapter(
    200,
    {'ok': true, 'data': data},
  );
  return api;
}

/// UserSummary fixture（字段对齐 server model.UserSummary json tag）。
Map<String, dynamic> _userJson(String username, {String? nickname}) => {
      'username': username,
      'nickname': nickname,
      'avatar_url': '',
    };

/// Incoming/Outgoing FriendRequest fixture（server enrichFriendRequests 输出）。
/// 字段：request_id / status / created_at / user（对方摘要）。
Map<String, dynamic> _requestJson(String id, Map<String, dynamic> user) => {
      'request_id': id,
      'status': 'pending',
      'created_at': '2026-07-04T10:00:00Z',
      'user': user,
    };

/// CreateRequest 响应 fixture（server CreateRequest 输出，对方摘要在 to_user）。
Map<String, dynamic> _createResponseJson(String id, Map<String, dynamic> toUser) => {
      'request_id': id,
      'status': 'pending',
      'to_user': toUser,
    };

void main() {
  group('friend 6 method 类型化', () {
    test('searchUsers 返 List<UserSummary>', () async {
      final api = _api([_userJson('alice'), _userJson('bob')]);
      final result = await api.searchUsers('a');
      expect(result, isA<List<UserSummary>>());
      expect(result.length, 2);
      expect(result.first.username, 'alice');
      expect(result.last.username, 'bob');
    });

    test('getUserByUsername 返 UserSummary', () async {
      final api = _api(_userJson('dave', nickname: 'Dave'));
      final user = await api.getUserByUsername('dave');
      expect(user, isA<UserSummary>());
      expect(user.username, 'dave');
      expect(user.nickname, 'Dave');
    });

    test('createFriendRequest 返 FriendRequest（server to_user 重映射为 user）', () async {
      final api = _api(_createResponseJson(
        'r1',
        _userJson('dave', nickname: 'Dave'),
      ));
      final req = await api.createFriendRequest('dave');
      expect(req, isA<FriendRequest>());
      expect(req.id, 'r1');
      expect(req.status, FriendshipStatus.pending);
      expect(req.user.username, 'dave');
      expect(req.user.nickname, 'Dave');
    });

    test('listIncomingFriendRequests 返 List<FriendRequest>', () async {
      final api = _api([
        _requestJson('r1', _userJson('alice')),
        _requestJson('r2', _userJson('bob')),
      ]);
      final result = await api.listIncomingFriendRequests();
      expect(result, isA<List<FriendRequest>>());
      expect(result.length, 2);
      expect(result.first.id, 'r1');
      expect(result.first.user.username, 'alice');
      expect(result.last.id, 'r2');
    });

    test('listOutgoingFriendRequests 返 List<FriendRequest>', () async {
      final api = _api([_requestJson('r3', _userJson('carol'))]);
      final result = await api.listOutgoingFriendRequests();
      expect(result, isA<List<FriendRequest>>());
      expect(result.length, 1);
      expect(result.first.id, 'r3');
      expect(result.first.user.username, 'carol');
    });

    test('listFriends 返 List<UserSummary>', () async {
      final api = _api([
        _userJson('alice', nickname: 'Alice'),
        _userJson('bob'),
      ]);
      final result = await api.listFriends();
      expect(result, isA<List<UserSummary>>());
      expect(result.length, 2);
      expect(result.first.username, 'alice');
      expect(result.first.nickname, 'Alice');
      expect(result.last.username, 'bob');
    });
  });
}
