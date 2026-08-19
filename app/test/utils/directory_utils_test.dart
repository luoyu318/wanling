import 'package:wanling_core/models/conversation.dart';
import 'package:app/providers/agent_status_provider.dart';
import 'package:app/utils/directory_utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('groupByDirectory', () {
    test('splits sessions by directory', () {
      final sessions = [
        Conversation(id: '1', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 1), createdAt: DateTime(2026, 7, 1), directory: '/proj/src'),
        Conversation(id: '2', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 2), createdAt: DateTime(2026, 7, 2), directory: '/proj/src'),
        Conversation(id: '3', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 3), createdAt: DateTime(2026, 7, 3), directory: '/proj/docs'),
        Conversation(id: '4', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 4), createdAt: DateTime(2026, 7, 4)),
      ];
      final result = groupByDirectory(sessions);
      expect(result.keys, contains('/proj/src'));
      expect(result.keys, contains('/proj/docs'));
      expect(result.keys, contains(null));
      expect(result['/proj/src']!.length, 2);
      expect(result['/proj/docs']!.length, 1);
      expect(result[null]!.length, 1);
    });

    test('sorts sessions by lastMessageAt descending within group', () {
      final sessions = [
        Conversation(id: '1', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 1), createdAt: DateTime(2026, 7, 1), directory: '/proj'),
        Conversation(id: '2', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 5), createdAt: DateTime(2026, 7, 5), directory: '/proj'),
      ];
      final result = groupByDirectory(sessions);
      expect(result['/proj']![0].id, '2');
      expect(result['/proj']![1].id, '1');
    });

    test('returns empty map for empty input', () {
      expect(groupByDirectory([]), isEmpty);
    });
  });

  group('buildDirectoryList', () {
    test('builds sorted DirectoryInfo list', () {
      final grouped = <String?, List<Conversation>>{
        '/proj/src': [
          Conversation(id: '1', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 1), createdAt: DateTime(2026, 7, 1), unreadCount: 2, directory: '/proj/src'),
          Conversation(id: '2', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 2), createdAt: DateTime(2026, 7, 2), unreadCount: 1, directory: '/proj/src'),
        ],
        null: [
          Conversation(id: '3', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 3), createdAt: DateTime(2026, 7, 3), directory: null),
        ],
      };
      final list = buildDirectoryList(grouped, ['/proj/src'], {});
      expect(list.length, 2);
      expect(list[0].path, '/proj/src');
      expect(list[0].sessionCount, 2);
      expect(list[0].unreadCount, 3);  // 2 + 1
      expect(list[1].path, null);       // 未归类
    });

    test('puts null (uncategorized) at the end', () {
      final grouped = <String?, List<Conversation>>{
        null: [Conversation(id: '1', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 1), createdAt: DateTime(2026, 7, 1))],
        '/a': [Conversation(id: '2', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 2), createdAt: DateTime(2026, 7, 2), directory: '/a')],
      };
      final list = buildDirectoryList(grouped, [], {});
      expect(list.last.path, isNull);
    });

    test('aggregates pendingCount across sessions', () {
      final grouped = <String?, List<Conversation>>{
        '/proj': [
          Conversation(id: '1', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 1), createdAt: DateTime(2026, 7, 1), directory: '/proj', pendingCount: 2),
          Conversation(id: '2', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 2), createdAt: DateTime(2026, 7, 2), directory: '/proj', pendingCount: 1),
        ],
      };
      final list = buildDirectoryList(grouped, ['/proj'], {});
      expect(list.first.pendingCount, 3);
    });

    test('busyCount 正确填充到 DirectoryInfo', () {
      final s1 = Conversation(
        id: 'c1',
        type: 'agent_session',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime(2025, 7, 22),
        createdAt: DateTime(2025, 7, 22),
        directory: '/a',
      );
      final s2 = Conversation(
        id: 'c2',
        type: 'agent_session',
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime(2025, 7, 22),
        createdAt: DateTime(2025, 7, 22),
        directory: '/a',
      );
      final grouped = groupByDirectory([s1, s2]);
      final statusMap = <String, AgentStatus>{
        'c1': const AgentStatus(type: AgentStatusType.busy),
      };
      final dirs = buildDirectoryList(grouped, ['/a'], statusMap);
      expect(dirs.length, 1);
      expect(dirs[0].busyCount, 1);
      expect(dirs[0].sessionCount, 2);
    });
  });

  group('computeUnreadCount', () {
    test('sums unreadCount across sessions', () {
      final sessions = [
        Conversation(id: '1', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 1), createdAt: DateTime(2026, 7, 1), unreadCount: 2),
        Conversation(id: '2', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 2), createdAt: DateTime(2026, 7, 2), unreadCount: 3),
      ];
      expect(computeUnreadCount(sessions), 5);
    });

    test('returns 0 for empty list', () {
      expect(computeUnreadCount([]), 0);
    });
  });

  group('computePendingCount', () {
    test('sums pendingCount across sessions', () {
      final sessions = [
        Conversation(id: '1', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 1), createdAt: DateTime(2026, 7, 1), pendingCount: 2),
        Conversation(id: '2', type: 'agent_session', participants: [], lastMessageContent: null, lastMessageAt: DateTime(2026, 7, 2), createdAt: DateTime(2026, 7, 2), pendingCount: 3),
      ];
      expect(computePendingCount(sessions), 5);
    });

    test('returns 0 for empty list', () {
      expect(computePendingCount([]), 0);
    });
  });

  group('pathLastTwoSegments', () {
    test('returns last two segments for deep path', () {
      expect(pathLastTwoSegments('/proj/a/b/src'), 'b/src');
    });

    test('returns single segment for short path', () {
      expect(pathLastTwoSegments('/src'), 'src');
      expect(pathLastTwoSegments('src'), 'src');
    });

    test('returns empty string for null', () {
      expect(pathLastTwoSegments(null), '');
    });

    test('handles trailing slash', () {
      expect(pathLastTwoSegments('/a/b/'), 'a/b');
    });
  });

  group('pathLastSegment', () {
    test('returns last segment for deep path', () {
      expect(pathLastSegment('/proj/a/b/src'), 'src');
    });

    test('returns input when single segment', () {
      expect(pathLastSegment('/src'), 'src');
      expect(pathLastSegment('src'), 'src');
    });

    test('returns empty string for null or empty', () {
      expect(pathLastSegment(null), '');
      expect(pathLastSegment(''), '');
    });

    test('handles trailing slash', () {
      expect(pathLastSegment('/a/b/'), 'b');
    });
  });

  group('directoryColor', () {
    test('returns neutral grey for null or empty path', () {
      expect(directoryColor(null), const Color(0xFFF0F0F0));
      expect(directoryColor(''), const Color(0xFFF0F0F0));
    });

    test('returns stable palette color for same path', () {
      expect(directoryColor('/proj/src'), directoryColor('/proj/src'));
    });

    test('returns palette color within defined set', () {
      const palette = [
        Color(0xFFE8F4FD),
        Color(0xFFFDE8F4),
        Color(0xFFF0E6FF),
        Color(0xFFFFF3E0),
        Color(0xFFE8F5E9),
        Color(0xFFFFEBEE),
        Color(0xFFE0F7FA),
        Color(0xFFFFF9C4),
        Color(0xFFF1F8E9),
        Color(0xFFFCE4EC),
        Color(0xFFEDE7F6),
        Color(0xFFE0F2F1),
      ];
      expect(palette, contains(directoryColor('/anything')));
    });
  });

  group('lightColorFor', () {
    test('returns stable color for same key', () {
      expect(lightColorFor('abc'), lightColorFor('abc'));
    });

    test('returns different colors for different keys (spread)', () {
      final colors = <Color>{};
      for (var i = 0; i < 50; i++) {
        colors.add(lightColorFor('session-$i'));
      }
      // 12 色调色板,50 个 key 应至少覆盖 8 个以上槽位
      expect(colors.length, greaterThan(7));
    });
  });

  group('directoryInitial', () {
    test('returns uppercase ASCII letter from last segment', () {
      expect(directoryInitial('/proj/src'), 'S');
      expect(directoryInitial('abc'), 'A');
    });

    test('returns first char as-is for non-ASCII (e.g. CJK)', () {
      expect(directoryInitial('工作/项目A'), '项');
    });

    test('returns ? for null or empty', () {
      expect(directoryInitial(null), '?');
      expect(directoryInitial(''), '?');
      expect(directoryInitial('/'), '?');
    });
  });

  group('computeBusyCount', () {
    Conversation mkConv(String id, {String? dir}) => Conversation(
      id: id,
      type: 'agent_session',
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime(2025, 1, 1),
      createdAt: DateTime(2025, 1, 1),
      directory: dir,
    );

    test('空 statusMap 返回 0', () {
      final sessions = [mkConv('c1'), mkConv('c2')];
      expect(computeBusyCount(sessions, {}), 0);
    });

    test('statusMap 中 busy + retry 都计入', () {
      final sessions = [mkConv('c1'), mkConv('c2'), mkConv('c3')];
      final statusMap = <String, AgentStatus>{
        'c1': const AgentStatus(type: AgentStatusType.busy),
        'c2': const AgentStatus(type: AgentStatusType.retry, attempt: 2, message: 'timeout'),
      };
      expect(computeBusyCount(sessions, statusMap), 2);
    });

    test('statusMap 中有不在 sessions 里的 conv 不计入', () {
      final sessions = [mkConv('c1')];
      final statusMap = <String, AgentStatus>{
        'c1': const AgentStatus(type: AgentStatusType.busy),
        'cX': const AgentStatus(type: AgentStatusType.busy),
      };
      expect(computeBusyCount(sessions, statusMap), 1);
    });
  });
}
