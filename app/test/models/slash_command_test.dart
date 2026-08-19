import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/slash_command.dart';

void main() {
  group('SlashCommand', () {
    test('fromJson 解析 source 字段', () {
      final cmd = SlashCommand.fromJson({
        'name': 'compact',
        'template': '/compact',
        'description': '压缩上下文',
        'source': 'command',
      });
      expect(cmd.name, 'compact');
      expect(cmd.template, '/compact');
      expect(cmd.description, '压缩上下文');
      expect(cmd.source, 'command');
    });

    test('fromJson source 缺失时降级为空串', () {
      final cmd = SlashCommand.fromJson({
        'name': 'test',
        'template': '/test',
      });
      expect(cmd.source, '');
    });

    test('toJson 包含 source 字段,不含 has_args', () {
      const cmd = SlashCommand(
        name: 'review',
        template: '/review',
        description: 'code review',
        source: 'command',
      );
      final json = cmd.toJson();
      expect(json['source'], 'command');
      expect(json.containsKey('has_args'), isFalse);
    });

    test('== / hashCode 基于 4 字段(name+template+description+source)', () {
      const a = SlashCommand(
        name: 'compact', template: '/compact',
        description: '压缩', source: 'command',
      );
      const b = SlashCommand(
        name: 'compact', template: '/compact',
        description: '压缩', source: 'command',
      );
      const c = SlashCommand(
        name: 'compact', template: '/compact',
        description: '压缩', source: 'skill',
      );
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });
}
