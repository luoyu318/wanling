import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/participant.dart';
import 'package:wanling_core/models/user_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Conversation JSON 往返', () {
    test('toJson → fromJson 应等于原对象(dm_user_agent)', () {
      final original = Conversation(
        id: 'c1',
        type: 'dm_user_agent',
        title: null,
        avatarUrl: null,
        agent: AgentSummary(id: 'a1', name: 'Bot', avatarUrl: 'http://a', status: AgentStatus.online),
        otherUser: null,
        participants: const [],
        lastMessageContent: {'msg_type': 'text', 'data': {'text': 'hi'}},
        lastMessageAt: DateTime.utc(2026, 7, 5, 10, 0, 0),
        createdAt: DateTime.utc(2026, 7, 1),
        unreadCount: 3,
        lastMessageSenderId: 'a1',
        lastMessageSenderType: 'agent',
      );
      final encoded = original.toJson();
      final decoded = Conversation.fromJson(encoded);
      expect(decoded.id, original.id);
      expect(decoded.type, original.type);
      expect(decoded.agent!.id, original.agent!.id);
      expect(decoded.lastMessageContent!['msg_type'], 'text');
      expect(decoded.unreadCount, 3);
    });

    test('toJson 群聊场景含 participants 序列化', () {
      final p = Participant(
        memberId: 'u2',
        memberType: 'user',
        role: 'member',
        username: 'bob',
        nickname: 'Bob',
        avatarUrl: '',
      );
      final conv = Conversation(
        id: 'c2',
        type: 'group_user',
        title: '群聊',
        avatarUrl: null,
        participants: [p],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
      );
      final encoded = conv.toJson();
      expect(encoded['participants'], isA<List>());
      final decoded = Conversation.fromJson(encoded);
      expect(decoded.participants.length, 1);
      expect(decoded.participants.first.memberId, 'u2');
    });

    test('agent_session 会话被识别为群聊样式且 isAgentSession 为 true', () {
      final conv = Conversation(
        id: 'c3',
        type: 'agent_session',
        title: 'OC 会话',
        avatarUrl: null,
        agent: AgentSummary(
            id: 'a1', name: 'OC', status: AgentStatus.online, type: 'opencode'),
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 5),
        createdAt: DateTime.utc(2026, 7, 1),
      );
      expect(conv.isAgentSession, isTrue);
      expect(conv.isGroup, isTrue,
          reason: 'agent_session 应纳入 isGroup 走群聊渲染样式');
      expect(conv.displayName, 'OC 会话');
    });
  });

  group('UserSummary JSON 往返', () {
    test('toJson → fromJson 应等于原对象', () {
      final original = UserSummary(
        username: 'alice',
        nickname: 'Alice',
        avatarUrl: 'http://a',
      );
      final encoded = original.toJson();
      final decoded = UserSummary.fromJson(encoded);
      expect(decoded.username, original.username);
      expect(decoded.nickname, original.nickname);
      expect(decoded.avatarUrl, original.avatarUrl);
    });
  });

  group('Participant JSON 往返', () {
    test('toJson → fromJson 应等于原对象', () {
      final original = Participant(
        memberId: 'u1',
        memberType: 'user',
        role: 'owner',
        username: 'alice',
        nickname: 'Alice',
        avatarUrl: 'http://a',
      );
      final encoded = original.toJson();
      final decoded = Participant.fromJson(encoded);
      expect(decoded.memberId, original.memberId);
      expect(decoded.memberType, original.memberType);
      expect(decoded.role, original.role);
    });
  });
}
