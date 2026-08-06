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
  group('groupAggregateElements 连续 tool_card 分组', () {
    test('连续 tool_card 合并成一组', () {
      final groups = groupAggregateElements([tool('t1', 'bash'), tool('t2', 'read')]);
      expect(groups.length, 1);
      expect(groups.first, isA<ToolGroupSlot>());
      expect((groups.first as ToolGroupSlot).cards.length, 2);
    });

    test('被 markdown 隔开的 tool_card 断开成两组', () {
      final groups = groupAggregateElements([
        tool('t1', 'bash'),
        {'type': 'markdown', 'element_id': 'm1', 'data': {'text': 'x'}},
        tool('t2', 'read'),
      ]);
      expect(groups.length, 3);
      expect(groups[0], isA<ToolGroupSlot>());
      expect(groups[1], isA<SingleElementSlot>());
      expect(groups[2], isA<ToolGroupSlot>());
    });

    test('task 子 agent 卡不参与折叠(单独 Slot)', () {
      final groups = groupAggregateElements([tool('t1', 'task', status: 'completed')]);
      expect(groups.length, 1);
      expect(groups.first, isA<SingleElementSlot>());
    });

    test('permission/question 卡不折叠,单个 tool_card 折叠 N=1', () {
      final groups = groupAggregateElements([
        tool('t1', 'bash'),
        {'type': 'permission_card', 'element_id': 'p1', 'data': const {}},
        {'type': 'question_card', 'element_id': 'q1', 'data': const {}},
      ]);
      expect(groups.length, 3);
      expect((groups[0] as ToolGroupSlot).cards.length, 1);
    });
  });
}
