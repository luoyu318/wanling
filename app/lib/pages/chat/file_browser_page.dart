import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../models/file_entry.dart';
import '../../providers/file_browser_provider.dart';
import '../../services/api_service.dart' show RpcException;
import '../../widgets/chat/file_entry_icon.dart';

class FileBrowserPage extends ConsumerStatefulWidget {
  final String agentId;
  final String convId;
  final String? cwd;

  const FileBrowserPage({
    super.key,
    required this.agentId,
    required this.convId,
    this.cwd,
  });

  @override
  ConsumerState<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends ConsumerState<FileBrowserPage> {
  late final FileBrowserKey _key = (agentId: widget.agentId, convId: widget.convId);

  String _basename(String path) {
    final i = path.lastIndexOf('/');
    return i >= 0 && i < path.length - 1 ? path.substring(i + 1) : path;
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fileBrowserProvider(_key));
    final notifier = ref.read(fileBrowserProvider(_key).notifier);
    final entries = state.entries.valueOrNull ?? const <FileEntry>[];
    final dirs = entries.where((e) => e.isDir).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final files = entries.where((e) => !e.isDir).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final currentName = state.currentPath == '.' || state.currentPath.isEmpty
        ? (widget.cwd == null || widget.cwd!.isEmpty ? '工作目录' : _basename(widget.cwd!))
        : _basename(state.currentPath);
    final parentPath = state.pathStack.isEmpty
        ? null
        : (state.pathStack.last == '.' ? '工作目录' : _basename(state.pathStack.last));

    return PopScope(
      canPop: state.pathStack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) notifier.goUp();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF2F2F7),
        appBar: AppBar(
          backgroundColor: const Color(0xFFF9F9F9),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              if (state.pathStack.isNotEmpty) {
                notifier.goUp();
              } else {
                context.pop();
              }
            },
          ),
          title: Column(
            children: [
              Text(
                currentName,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111111),
                ),
              ),
              if (parentPath != null)
                Text(
                  '从 $parentPath 进入',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F99)),
                ),
            ],
          ),
          centerTitle: true,
        ),
        body: state.entries.when(
          loading: () => const _LoadingPane(),
          error: (err, _) => _EntriesErrorView(
            error: err,
            onRetry: () => notifier.loadDirectory(state.currentPath),
          ),
          data: (_) => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              if (dirs.isNotEmpty) ...[
                const _SectionLabel('文件夹'),
                const SizedBox(height: 6),
                _CardGroup(
                  entries: dirs,
                  onTap: (e) => notifier.enterDirectory(e.name),
                ),
              ],
              if (files.isNotEmpty) ...[
                if (dirs.isNotEmpty) const SizedBox(height: 24),
                const _SectionLabel('文件'),
                const SizedBox(height: 6),
                _CardGroup(
                  entries: files,
                  onTap: (e) => context.push(
                    '/file-preview/${widget.agentId}/${widget.convId}',
                    extra: e,
                  ),
                ),
              ],
              if (state.entriesTruncated)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Center(
                    child: Text(
                      '目录项过多,只显示前 500 项',
                      style: TextStyle(fontSize: 11, color: Color(0xFF999999)),
                    ),
                  ),
                ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: Color(0xFF8A8F99),
        ),
      ),
    );
  }
}

class _CardGroup extends StatelessWidget {
  final List<FileEntry> entries;
  final ValueChanged<FileEntry> onTap;

  const _CardGroup({required this.entries, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            _EntryTile(entry: entries[i], onTap: () => onTap(entries[i])),
            if (i != entries.length - 1)
              const Divider(height: 0.5, indent: 56, color: Color(0xFFF0F0F0)),
          ],
        ],
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  final FileEntry entry;
  final VoidCallback onTap;

  const _EntryTile({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = _tileColor(entry);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: FileEntryIcon(entry: entry, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: entry.isDir ? FontWeight.w500 : FontWeight.normal,
                      color: const Color(0xFF111111),
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!entry.isDir)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        _formatBytes(entry.size),
                        style: const TextStyle(fontSize: 12, color: Color(0xFF8A8F99)),
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              entry.isDir ? Icons.chevron_right : Icons.north_east,
              size: 18,
              color: const Color(0xFFC8C9CC),
            ),
          ],
        ),
      ),
    );
  }

  Color _tileColor(FileEntry entry) {
    if (entry.isDir) return const Color(0xFF5B7CFA);
    return const Color(0xFF8A8F99);
  }
}

class _LoadingPane extends StatelessWidget {
  const _LoadingPane();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF5B8BF7)),
      ),
    );
  }
}

class _EntriesErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _EntriesErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    String title = '加载失败';
    String subtitle = error.toString();
    if (error is RpcException) {
      final rpcError = error as RpcException;
      if (rpcError.code == -32604) {
        title = '非 git 仓库';
        subtitle = '该会话目录不是 git 仓库,无法浏览';
      } else if (rpcError.code == -32001) {
        title = 'Agent 离线';
        subtitle = '请稍后重试';
      }
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 32, color: Color(0xFFFA5151)),
            const SizedBox(height: 8),
            Text(title, style: const TextStyle(fontSize: 13, color: Color(0xFF333333))),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF07C160),
                side: const BorderSide(color: Color(0xFF07C160)),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
