import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/agent_sub_key_info.dart';

void main() {
  group('AgentSubKeyInfo.fromJson', () {
    test('活跃密钥:last_used_at/revoked_at 字段缺席(omitempty)而非 null', () {
      final key = AgentSubKeyInfo.fromJson({
        'id': 'k1',
        'name': '技能授权',
        'agent_id': 'a1',
        'created_at': '2026-09-01T10:00:00Z',
      });
      expect(key.id, 'k1');
      expect(key.name, '技能授权');
      expect(key.agentId, 'a1');
      expect(key.createdAt, DateTime.parse('2026-09-01T10:00:00Z'));
      expect(key.lastUsedAt, isNull);
      expect(key.revokedAt, isNull);
      expect(key.isRevoked, isFalse);
    });

    test('字段显式 null 与缺席等价', () {
      final key = AgentSubKeyInfo.fromJson({
        'id': 'k2',
        'name': 'n',
        'agent_id': 'a1',
        'created_at': '2026-09-01T10:00:00Z',
        'last_used_at': null,
        'revoked_at': null,
      });
      expect(key.lastUsedAt, isNull);
      expect(key.revokedAt, isNull);
    });

    test('已吊销 + 有最后使用时间', () {
      final key = AgentSubKeyInfo.fromJson({
        'id': 'k3',
        'name': 'n',
        'agent_id': 'a1',
        'created_at': '2026-09-01T10:00:00Z',
        'last_used_at': '2026-09-01T12:00:00Z',
        'revoked_at': '2026-09-02T08:00:00Z',
      });
      expect(key.lastUsedAt, DateTime.parse('2026-09-01T12:00:00Z'));
      expect(key.revokedAt, DateTime.parse('2026-09-02T08:00:00Z'));
      expect(key.isRevoked, isTrue);
    });

    test('==/hashCode 按 id 判等', () {
      final a = AgentSubKeyInfo.fromJson({
        'id': 'k1', 'name': 'x', 'agent_id': 'a1',
        'created_at': '2026-09-01T10:00:00Z',
      });
      final b = AgentSubKeyInfo.fromJson({
        'id': 'k1', 'name': 'y', 'agent_id': 'a2',
        'created_at': '2026-09-02T10:00:00Z',
      });
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
