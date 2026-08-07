import 'package:app/rendering/tool_group_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> tool(String id, String name, {String status = 'completed'}) {
  return {
    'type': 'tool_card',
    'element_id': id,
    'data': {'name': name, 'status': status, 'input': const {}},
  };
}

void main() {
  group('groupAggregateElements 按折叠类别分组', () {
    test('同类连续合并:bash×2 → 1 个命令组', () {
      final groups = groupAggregateElements([tool('t1', 'bash'), tool('t2', 'bash')]);
      expect(groups.length, 1);
      expect(groups.first, isA<ToolGroupSlot>());
      expect((groups.first as ToolGroupSlot).cards.length, 2);
    });

    test('不同类别中断拆组:bash, read → 命令组+探索组', () {
      final groups = groupAggregateElements([tool('t1', 'bash'), tool('t2', 'read')]);
      expect(groups.length, 2);
      expect((groups[0] as ToolGroupSlot).cards.single['data']!['name'], 'bash');
      expect((groups[1] as ToolGroupSlot).cards.single['data']!['name'], 'read');
    });

    test('完整示例:[bash,bash,read,grep,bash,write,edit,read] → 5 组', () {
      final groups = groupAggregateElements([
        tool('t1', 'bash'), tool('t2', 'bash'), tool('t3', 'read'),
        tool('t4', 'grep'), tool('t5', 'bash'), tool('t6', 'write'),
        tool('t7', 'edit'), tool('t8', 'read'),
      ]);
      expect(groups.length, 5);
      final sizes = groups.map((g) => (g as ToolGroupSlot).cards.length).toList();
      expect(sizes, [2, 2, 1, 2, 1]);
    });

    test('read+grep 同组但计数分读取/搜索(单条也折叠)', () {
      final groups = groupAggregateElements([tool('t1', 'read')]);
      expect(groups.length, 1);
      expect(groups.first, isA<ToolGroupSlot>());
      expect((groups.first as ToolGroupSlot).cards.length, 1);
    });

    test('todowrite 隐藏不产出 Slot', () {
      final groups = groupAggregateElements([tool('t1', 'todowrite'), tool('t2', 'read')]);
      expect(groups.length, 1);
      expect((groups[0] as ToolGroupSlot).cards.single['data']!['name'], 'read');
    });

    test('webfetch/task 平铺不折叠', () {
      final groups = groupAggregateElements([tool('t1', 'webfetch'), tool('t2', 'read')]);
      expect(groups.length, 2);
      expect(groups[0], isA<SingleElementSlot>());
      expect(groups[1], isA<ToolGroupSlot>());
    });

    test('被 markdown 隔开的两组 read 拆成两组', () {
      final groups = groupAggregateElements([
        tool('t1', 'read'),
        {'type': 'markdown', 'element_id': 'm1', 'data': {'text': 'x'}},
        tool('t2', 'read'),
      ]);
      expect(groups.length, 3);
      expect(groups[0], isA<ToolGroupSlot>());
      expect(groups[1], isA<SingleElementSlot>());
      expect(groups[2], isA<ToolGroupSlot>());
    });

    test('task 子 agent 卡平铺(不折叠)', () {
      final groups = groupAggregateElements([tool('t1', 'task', status: 'completed')]);
      expect(groups.length, 1);
      expect(groups.first, isA<SingleElementSlot>());
    });
  });
}
