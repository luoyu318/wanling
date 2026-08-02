import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/agent.dart';
import '../utils/directory_utils.dart';
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
            Container(
              height: 80,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Row(
                  children: [
                    Avatar(
                      name: agent!.name,
                      url: agent!.avatarUrl,
                      size: 40,
                      radius: 6,
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            agent!.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            (agent!.bio != null && agent!.bio!.isNotEmpty)
                                ? agent!.bio!
                                : '工作目录',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xB3FFFFFF),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
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
