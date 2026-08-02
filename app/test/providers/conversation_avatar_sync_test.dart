import 'package:app/models/agent.dart' show Agent, AgentStatus, AgentSummary;
import 'package:app/models/conversation.dart';
import 'package:app/providers/conversation_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('syncAgentAvatarsToBgService', () {
    test('空会话列表不抛异常', () {
      // 原生平台未注册时 invoke 抛异常,try-catch 兜底
      expect(() => syncAgentAvatarsToBgService([]), returnsNormally);
    });

    test('有会话列表时正常遍历不抛异常(测试环境 invoke 走 catch)', () {
      final convs = [
        _mkConv('agent-1', '/api/files/a1'),
        _mkConv('agent-2', null),
        _mkConv('agent-3', 'https://example.com/a.png'),
      ];
      expect(() => syncAgentAvatarsToBgService(convs), returnsNormally);
    });

    test('空 agentId 的条目被跳过不抛异常', () {
      final convs = [
        _mkConv('', '/api/files/x'),
        _mkConv('agent-1', null),
      ];
      expect(() => syncAgentAvatarsToBgService(convs), returnsNormally);
    });
  });
}

Conversation _mkConv(String agentId, String? avatarUrl) {
  return Conversation(
    id: 'conv-$agentId',
    type: 'dm_user_agent',
    agent: AgentSummary(
      id: agentId,
      name: 'test',
      status: AgentStatus.offline,
      avatarUrl: avatarUrl,
    ),
    participants: [],
    lastMessageContent: null,
    lastMessageAt: DateTime.now(),
    createdAt: DateTime.now(),
  );
}
