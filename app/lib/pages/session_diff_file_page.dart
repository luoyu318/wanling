import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/session_diff_provider.dart';
import '../widgets/chat/diff_patch_viewer.dart';

class SessionDiffFilePage extends ConsumerWidget {
  final String agentId;
  final String convId;
  final int idx;

  const SessionDiffFilePage({
    super.key,
    required this.agentId,
    required this.convId,
    required this.idx,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (agentId: agentId, convId: convId);
    final state = ref.watch(sessionDiffProvider(key));

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        surfaceTintColor: Colors.transparent,
        shape: const Border(
          bottom: BorderSide(color: Color(0xFFD9D9D9), width: 0.5),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        centerTitle: true,
        title: state.maybeWhen(
          data: (files) => Text(
            idx >= 0 && idx < files.length ? (files[idx].file ?? '(unknown)') : '',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          orElse: () => const Text(''),
        ),
        actions: const [
          IconButton(
            icon: Icon(Icons.copy, size: 16),
            tooltip: '复制',
            onPressed: null,
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (err, _) => Center(
          child: Text(
            '加载失败: $err',
            style: const TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
        ),
        data: (files) {
          if (idx < 0 || idx >= files.length) {
            return const Center(
              child: Text(
                '文件不存在',
                style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
              ),
            );
          }
          final file = files[idx];
          return Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  border: Border(
                    bottom: BorderSide(color: Color(0xFFE4E4E4), width: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      '+${file.additions}',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF07C160)),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '−${file.deletions}',
                      style: const TextStyle(fontSize: 11, color: Color(0xFFFA5151)),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      file.status ?? '',
                      style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: DiffPatchViewer(patch: file.patch ?? ''),
              ),
            ],
          );
        },
      ),
    );
  }
}
