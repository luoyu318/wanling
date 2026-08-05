import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/agent.dart';
import '../utils/directory_utils.dart';
import 'agent_badge.dart';
import 'avatar.dart';
import 'directory_tile.dart';
import 'long_press_detector.dart';

class DirectoryPanel extends ConsumerWidget {
  final AgentSummary? agent;
  final List<DirectoryInfo> directories;
  final String? selectedPath;
  final bool showHeader;
  final void Function(String? path) onSelected;
  final void Function(int oldIndex, int newIndex) onReorder;
  final VoidCallback onNewSession;

  const DirectoryPanel({
    super.key,
    this.agent,
    required this.directories,
    required this.selectedPath,
    required this.showHeader,
    required this.onSelected,
    required this.onReorder,
    required this.onNewSession,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ColoredBox(
      color: Colors.white,
      child: Column(
        children: [
          if (agent != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
              child: Row(
                children: [
                  Avatar(
                    name: agent!.name,
                    url: agent!.avatarUrl,
                    size: 52,
                    radius: 10,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                agent!.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF111111),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            AgentBadge(type: agent!.type),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: agent!.status == AgentStatus.online
                                    ? const Color(0xFF07C160)
                                    : const Color(0xFFCCCCCC),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              agent!.status == AgentStatus.online
                                  ? '在线'
                                  : '离线',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF999999),
                                fontWeight: FontWeight.w300,
                              ),
                            ),
                            if (agent!.bio != null &&
                                agent!.bio!.isNotEmpty) ...[
                              const Text(
                                '  |  ',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFFCCCCCC),
                                  fontWeight: FontWeight.w300,
                                ),
                              ),
                              Expanded(
                                child: Text(
                                  agent!.bio!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF999999),
                                    fontWeight: FontWeight.w300,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (showHeader)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '目录',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF999999),
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          Expanded(
            child: ReorderableListView(
              onReorderItem: (oldIndex, newIndex) {
                final legacyNewIndex =
                    newIndex > oldIndex ? newIndex + 1 : newIndex;
                onReorder(oldIndex, legacyNewIndex);
              },
              buildDefaultDragHandles: false,
              proxyDecorator: (child, _, _) => Material(
                elevation: 2,
                color: Colors.transparent,
                child: child,
              ),
              children: [
                for (final dir in directories)
                  LongPressDetector(
                    key: ValueKey(dir.path ?? '__uncategorized__'),
                    onLongPressStart: (_) => HapticFeedback.mediumImpact(),
                    child: ReorderableDelayedDragStartListener(
                      index: directories.indexOf(dir),
                      child: DirectoryTile(
                        info: dir,
                        isSelected: selectedPath == dir.path,
                        onTap: () => onSelected(dir.path),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(
            height: 1,
            thickness: 0.5,
            color: Color(0xFFE0E0E0),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: onNewSession,
          ),
        ],
      ),
    );
  }
}
