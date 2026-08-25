import 'package:wanling_core/models/agent.dart';
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
  });

  group('multiSession(注册表注入 + 老 server fallback)', () {
    test('Agent: server 注入值优先', () {
      final dsh = Agent.fromJson({
        'id': 'a1', 'name': 'n', 'status': 'online', 'type': 'dsh',
        'multi_session': true,
      });
      expect(dsh.isMultiSession, isTrue);
    });

    test('Agent: null(老 server 缺字段)时 fallback type==opencode', () {
      final oc = Agent.fromJson({
        'id': 'a2', 'name': 'n', 'status': 'online', 'type': 'opencode',
      });
      expect(oc.multiSession, isNull);
      expect(oc.isMultiSession, isTrue);

      final dshOld = Agent.fromJson({
        'id': 'a3', 'name': 'n', 'status': 'online', 'type': 'dsh',
      });
      // 老 server 不认识 dsh:路由退单聊(可接受的降级,升级 server 即恢复)
      expect(dshOld.isMultiSession, isFalse);
    });

    test('AgentSummary: 注入值与 fallback 同 Agent 口径', () {
      final s = AgentSummary.fromJson({
        'id': 'a4', 'name': 'n', 'status': 'offline', 'type': 'dsh',
        'multi_session': true,
      });
      expect(s.isMultiSession, isTrue);
      final legacy = AgentSummary.fromJson(
          {'id': 'a5', 'name': 'n', 'status': 'offline', 'type': ''});
      expect(legacy.isMultiSession, isFalse);
    });
  });
}
