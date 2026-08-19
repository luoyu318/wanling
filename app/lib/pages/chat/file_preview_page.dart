import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/file_content.dart';
import 'package:wanling_core/models/file_entry.dart';
import '../../providers/file_browser_provider.dart';
import 'package:wanling_core/services/api_service.dart' show RpcException;
import 'package:wanling_core/utils/snackbar.dart' show SnackBarType, showAppSnackBar;
import '../../widgets/chat/code_highlight_view.dart';

class FilePreviewPage extends ConsumerStatefulWidget {
  final FileBrowserKey browserKey;
  final FileEntry entry;

  const FilePreviewPage({
    super.key,
    required this.browserKey,
    required this.entry,
  });

  @override
  ConsumerState<FilePreviewPage> createState() => _FilePreviewPageState();
}

class _FilePreviewPageState extends ConsumerState<FilePreviewPage> {
  late final FileBrowserNotifier _notifier;

  @override
  void initState() {
    super.initState();
    _notifier = ref.read(fileBrowserProvider(widget.browserKey).notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifier.loadFileContent(widget.entry);
    });
  }

  @override
  void dispose() {
    scheduleMicrotask(_notifier.clearFileContent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(fileBrowserProvider(widget.browserKey));
    final content = state.previewContent;
    final entry = widget.entry;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: Column(
          children: [
            Text(
              entry.name,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Color(0xFF111111),
              ),
            ),
            Text(
              _formatBytes(entry.size),
              style: const TextStyle(fontSize: 11, color: Color(0xFF8A8F99)),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.content_copy, size: 20),
            onPressed: () => _copyContent(context, ref),
          ),
        ],
      ),
      body: content == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : content.when(
              loading: () => const _LoadingView(),
              error: (err, _) => _ErrorView(
                error: err,
                onRetry: () => ref
                    .read(fileBrowserProvider(widget.browserKey).notifier)
                    .loadFileContent(widget.entry),
              ),
              data: (c) => _PreviewBody(content: c),
            ),
    );
  }

  void _copyContent(BuildContext context, WidgetRef ref) {
    final c = ref.read(fileBrowserProvider(widget.browserKey)).previewContent?.value;
    final text = c?.content;
    if (text == null) return;
    Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      showAppSnackBar(context, '已复制', type: SnackBarType.success);
    }
  }
}

class _PreviewBody extends StatelessWidget {
  final FileContent content;
  const _PreviewBody({required this.content});

  @override
  Widget build(BuildContext context) {
    if (content.isBinary) {
      return const _EmptyState(
        icon: Icons.block,
        title: '该文件类型不支持预览',
      );
    }
    if (content.isImage) {
      return _ImageBody(content: content);
    }
    return CodeHighlightView(
      code: content.content ?? '',
      path: content.path,
      truncated: content.truncated,
      fileSizeBytes: content.size,
    );
  }
}

class _ImageBody extends StatelessWidget {
  final FileContent content;
  const _ImageBody({required this.content});

  @override
  Widget build(BuildContext context) {
    final bytes = base64Decode(content.contentBase64 ?? '');
    return Stack(
      children: [
        InteractiveViewer(
          child: Center(child: Image.memory(bytes)),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            color: const Color(0xCCFFFFFF),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              '${content.path.split('/').last} · ${_formatBytes(content.size)}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Color(0xFF999999),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF5B8BF7)),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  const _EmptyState({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: const Color(0xFFCCCCCC)),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontSize: 13, color: Color(0xFF555555))),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    String title = '加载失败';
    String subtitle = error.toString();
    if (error is RpcException) {
      final code = (error as RpcException).code;
      if (code == -32001) {
        title = 'Agent 离线';
        subtitle = '无法读取文件,请稍后重试';
      } else if (code == -32002) {
        title = '加载超时';
        subtitle = '文件较大或网络较慢';
      } else if (code == -32605) {
        title = '读取失败';
        subtitle = (error as RpcException).message;
      }
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 36, color: Color(0xFFFA5151)),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontSize: 13, color: Color(0xFF333333))),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 14),
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
