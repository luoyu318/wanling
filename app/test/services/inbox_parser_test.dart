import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/inbox_entry.dart';
import 'package:app/services/inbox_parser.dart';

void main() {
  const empty = InboxParserState();

  group('ingestCreate 四类 pending 卡', () {
    test('独立 permission_card pending 入队', () {
      final r = ingestCreate(empty, 'm1', 'c1', {
        'msg_type': 'permission_card',
        'data': {'status': 'pending', 'oc_request_id': 'oc1', 'action': 'bash'},
      });
      expect(r.added, hasLength(1));
      expect(r.added.first.kind, InboxCardKind.ocPermission);
      expect(r.added.first.entryKey, 'm1');
      expect(r.added.first.convId, 'c1');
    });

    test('独立 question_card 终态不入队', () {
      final r = ingestCreate(empty, 'm1', 'c1', {
        'msg_type': 'question_card',
        'data': {'status': 'answered'},
      });
      expect(r.added, isEmpty);
    });

    test('approvals 审批卡（msg_type=card）pending 入队，终态不入队', () {
      final r1 = ingestCreate(empty, 'm1', 'c1', {
        'msg_type': 'card',
        'data': {'state': 'pending', 'approval_id': 'a1'},
      });
      expect(r1.added.single.kind, InboxCardKind.approvalCard);
      final r2 = ingestCreate(empty, 'm2', 'c1', {
        'msg_type': 'card',
        'data': {'state': 'expired'},
      });
      expect(r2.added, isEmpty);
    });

    test('聚合卡建卡：elements 里的 pending 交互元素入队（entryKey 带 elementId）', () {
      final r = ingestCreate(empty, 'm1', 'c1', {
        'msg_type': 'aggregate_card',
        'data': {
          'state': 'generating',
          'elements': [
            {'type': 'markdown', 'element_id': 'md_1', 'data': {'text': 'hi'}},
            {
              'type': 'permission_card',
              'element_id': 'perm_1',
              'data': {'status': 'pending', 'oc_request_id': 'oc1'},
            },
          ],
        },
      });
      expect(r.added, hasLength(1));
      expect(r.added.first.entryKey, 'm1:perm_1');
      expect(r.added.first.elementId, 'perm_1');
      expect(r.added.first.kind, InboxCardKind.aggregateElement);
    });

    test('同一 msg 重复入队去重（幂等）', () {
      final r1 = ingestCreate(empty, 'm1', 'c1', {
        'msg_type': 'permission_card',
        'data': {'status': 'pending'},
      });
      final r2 = ingestCreate(r1.state, 'm1', 'c1', {
        'msg_type': 'permission_card',
        'data': {'status': 'pending'},
      });
      expect(r2.added, isEmpty);
    });
  });

  group('ingestUpdate 收敛', () {
    test('全量 UPDATE 终态 → 出队', () {
      final r1 = ingestCreate(empty, 'm1', 'c1', {
        'msg_type': 'permission_card',
        'data': {'status': 'pending'},
      });
      final r2 = ingestUpdate(r1.state, 'm1', 'c1', {
        'msg_type': 'permission_card',
        'data': {'status': 'approved'},
      });
      expect(r2.removedKeys, ['m1']);
      expect(r2.added, isEmpty);
    });

    test('聚合卡 update op 元素终态 → 出队该 entry', () {
      final r1 = ingestCreate(empty, 'm1', 'c1', {
        'msg_type': 'aggregate_card',
        'data': {
          'elements': [
            {
              'type': 'question_card',
              'element_id': 'q_1',
              'data': {'status': 'pending', 'oc_request_id': 'oc1'},
            },
          ],
        },
      });
      final r2 = ingestUpdate(r1.state, 'm1', 'c1', {
        'msg_type': 'aggregate_card',
        'data': {
          'op': 'update',
          'element_id': 'q_1',
          'data': {'status': 'answered', 'oc_request_id': 'oc1'},
        },
      });
      expect(r2.removedKeys, ['m1:q_1']);
    });

    test('聚合卡 append op 新 pending 元素 → 入队', () {
      final r1 = ingestCreate(empty, 'm1', 'c1', {
        'msg_type': 'aggregate_card',
        'data': {'elements': []},
      });
      final r2 = ingestUpdate(r1.state, 'm1', 'c1', {
        'msg_type': 'aggregate_card',
        'data': {
          'op': 'append',
          'element': {
            'type': 'permission_card',
            'element_id': 'perm_2',
            'data': {'status': 'pending'},
          },
        },
      });
      expect(r2.added.single.entryKey, 'm1:perm_2');
    });

    test('非聚合卡忽略未知 op / 非卡消息', () {
      final r = ingestUpdate(empty, 'm9', 'c1', {
        'msg_type': 'aggregate_card',
        'data': {'op': 'set_silent', 'silent': true},
      });
      expect(r.added, isEmpty);
      expect(r.removedKeys, isEmpty);
    });

    test('全量 UPDATE 聚合卡重新收敛（重建视图，不残留旧元素）', () {
      final r1 = ingestCreate(empty, 'm1', 'c1', {
        'msg_type': 'aggregate_card',
        'data': {
          'elements': [
            {
              'type': 'permission_card',
              'element_id': 'perm_1',
              'data': {'status': 'pending'},
            },
          ],
        },
      });
      // plugin 全量替换（无 op）：perm_1 已终态
      final r2 = ingestUpdate(r1.state, 'm1', 'c1', {
        'msg_type': 'aggregate_card',
        'data': {
          'elements': [
            {
              'type': 'permission_card',
              'element_id': 'perm_1',
              'data': {'status': 'denied'},
            },
          ],
        },
      });
      expect(r2.removedKeys, ['m1:perm_1']);
      expect(r2.added, isEmpty);
    });
  });
}
