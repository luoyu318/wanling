import 'package:app/models/agent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Agent JSON 往返', () {
    test('Agent.toJson → fromJson 应等于原对象', () {
      final original = Agent(
        id: 'a1',
        name: 'Bot',
        avatarUrl: 'http://a',
        bio: 'helper',
        status: AgentStatus.online,
      );
      final encoded = original.toJson();
      final decoded = Agent.fromJson(encoded);
      expect(decoded.id, original.id);
      expect(decoded.name, original.name);
      expect(decoded.avatarUrl, original.avatarUrl);
      expect(decoded.bio, original.bio);
      expect(decoded.status, AgentStatus.online);
    });

    test('AgentSummary.toJson → fromJson 应等于原对象', () {
      final original = AgentSummary(
        id: 'a1',
        name: 'Bot',
        avatarUrl: null,
        status: AgentStatus.offline,
      );
      final encoded = original.toJson();
      final decoded = AgentSummary.fromJson(encoded);
      expect(decoded.id, original.id);
      expect(decoded.name, original.name);
      expect(decoded.status, AgentStatus.offline);
    });

    test('AgentSummary 带 type 字段往返', () {
      final original = AgentSummary(
        id: 'a1',
        name: 'OC',
        avatarUrl: 'http://a',
        status: AgentStatus.online,
        type: 'opencode',
      );
      final encoded = original.toJson();
      expect(encoded['type'], 'opencode');
      final decoded = AgentSummary.fromJson(encoded);
      expect(decoded.type, 'opencode');
    });

    test('AgentSummary fromJson 缺 type 字段时回退空串(向后兼容)', () {
      final decoded = AgentSummary.fromJson({
        'id': 'a1',
        'name': 'Bot',
        'status': 'online',
      });
      expect(decoded.type, '');
    });

    test('AgentSummary 带 bio 字段往返', () {
      final original = AgentSummary(
        id: 'a1',
        name: 'OC',
        avatarUrl: 'http://a',
        status: AgentStatus.online,
        bio: 'OpenCode 长任务 agent',
      );
      final encoded = original.toJson();
      expect(encoded['bio'], 'OpenCode 长任务 agent');
      final decoded = AgentSummary.fromJson(encoded);
      expect(decoded.bio, 'OpenCode 长任务 agent');
    });

    test('AgentSummary bio null 默认不写 JSON', () {
      final original = AgentSummary(
        id: 'a1',
        name: 'OC',
        status: AgentStatus.online,
      );
      final encoded = original.toJson();
      expect(encoded.containsKey('bio'), isFalse);
    });
  });

  group('AgentCategory', () {
    test('字面量常量值稳定(协议契约,不可漂移)', () {
      expect(AgentCategory.hermes, 'hermes');
      expect(AgentCategory.opencode, 'opencode');
    });

    test('supportsMultiSession: opencode 为 true', () {
      expect(AgentCategory.supportsMultiSession(AgentCategory.opencode),
          isTrue);
    });

    test('supportsMultiSession: hermes / 空串(legacy) / 未知值为 false', () {
      expect(AgentCategory.supportsMultiSession(AgentCategory.hermes),
          isFalse);
      expect(AgentCategory.supportsMultiSession(''), isFalse);
      expect(AgentCategory.supportsMultiSession('unknown'), isFalse);
    });
  });
}
