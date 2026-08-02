import 'package:flutter/material.dart';
import '../models/conversation.dart';
import '../providers/agent_status_provider.dart';

class DirectoryInfo {
  final String? path;
  final int sessionCount;
  final int unreadCount;
  final int pendingCount;
  final int busyCount;

  const DirectoryInfo({
    this.path,
    required this.sessionCount,
    required this.unreadCount,
    this.pendingCount = 0,
    this.busyCount = 0,
  });
}

Map<String?, List<Conversation>> groupByDirectory(List<Conversation> sessions) {
  final map = <String?, List<Conversation>>{};
  for (final s in sessions) {
    map.putIfAbsent(s.directory, () => []);
    map[s.directory]!.add(s);
  }
  for (final list in map.values) {
    list.sort((a, b) => b.lastMessageAt.compareTo(a.lastMessageAt));
  }
  return map;
}

List<DirectoryInfo> buildDirectoryList(
  Map<String?, List<Conversation>> grouped,
  List<String> order,
  Map<String, AgentStatus> statusMap,
) {
  final result = <DirectoryInfo>[];
  final orderedSet = order.toSet();
  final unordered = <String?>[];

  for (final key in grouped.keys) {
    if (key == null) continue;
    if (!orderedSet.contains(key)) {
      unordered.add(key);
    }
  }

  for (final key in order) {
    final sessions = grouped[key];
    if (sessions == null || sessions.isEmpty) continue;
    result.add(DirectoryInfo(
      path: key,
      sessionCount: sessions.length,
      unreadCount: computeUnreadCount(sessions),
      pendingCount: computePendingCount(sessions),
      busyCount: computeBusyCount(sessions, statusMap),
    ));
  }

  unordered.sort();
  for (final key in unordered) {
    final sessions = grouped[key]!;
    result.add(DirectoryInfo(
      path: key,
      sessionCount: sessions.length,
      unreadCount: computeUnreadCount(sessions),
      pendingCount: computePendingCount(sessions),
      busyCount: computeBusyCount(sessions, statusMap),
    ));
  }

  final uncategorized = grouped[null];
  if (uncategorized != null && uncategorized.isNotEmpty) {
    result.add(DirectoryInfo(
      path: null,
      sessionCount: uncategorized.length,
      unreadCount: computeUnreadCount(uncategorized),
      pendingCount: computePendingCount(uncategorized),
      busyCount: computeBusyCount(uncategorized, statusMap),
    ));
  }

  return result;
}

int computeUnreadCount(List<Conversation> sessions) {
  return sessions.fold(0, (sum, c) => sum + c.unreadCount);
}

int computePendingCount(List<Conversation> sessions) {
  return sessions.fold(0, (sum, c) => sum + c.pendingCount);
}

int computeBusyCount(
    List<Conversation> sessions, Map<String, AgentStatus> statusMap) {
  return sessions.where((c) => statusMap.containsKey(c.id)).length;
}

String pathLastTwoSegments(String? path) {
  if (path == null || path.isEmpty) return '';
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length <= 2) return segments.join('/');
  return segments.sublist(segments.length - 2).join('/');
}

String pathLastSegment(String? path) {
  if (path == null || path.isEmpty) return '';
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  return segments.isEmpty ? '' : segments.last;
}

const _lightPalette = [
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

Color lightColorFor(String key) {
  return _lightPalette[key.hashCode.abs() % _lightPalette.length];
}

Color directoryColor(String? path) {
  if (path == null || path.isEmpty) {
    return const Color(0xFFF0F0F0);
  }
  return lightColorFor(path);
}

String directoryInitial(String? path) {
  final last = pathLastSegment(path);
  if (last.isEmpty) return '?';
  final firstRune = last.runes.first;
  if (firstRune >= 0x61 && firstRune <= 0x7A) {
    return String.fromCharCode(firstRune - 32);
  }
  return String.fromCharCode(firstRune);
}
