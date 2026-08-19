import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/session_diff.dart';
import 'package:wanling_core/providers/session_diff_provider.dart';
import 'package:wanling_core/theme/app_colors.dart';
import 'package:wanling_core/services/api_service.dart';

class SessionDiffPage extends ConsumerWidget {
  final String agentId;
  final String convId;

  const SessionDiffPage({
    super.key,
    required this.agentId,
    required this.convId,
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
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '变更文件',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            state.maybeWhen(
              data: (files) => Text(
                _summary(files),
                style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
              ),
              orElse: () => const SizedBox.shrink(),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: '刷新',
            onPressed: () => ref.read(sessionDiffProvider(key).notifier).load(),
          ),
        ],
      ),
      body: state.when(
        loading: () => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(height: 10),
              Text(
                '加载中...',
                style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
              ),
            ],
          ),
        ),
        error: (err, _) => _ErrorView(
          error: err,
          onRetry: () => ref.read(sessionDiffProvider(key).notifier).load(),
        ),
        data: (files) {
          if (files.isEmpty) {
            return const _EmptyView(
              icon: Icons.history,
              title: '暂无变更',
              subtitle: '本次会话尚未产生代码变更',
              showRetry: false,
            );
          }
          return RefreshIndicator(
            color: AppColors.accentGreen,
            onRefresh: () =>
                ref.read(sessionDiffProvider(key).notifier).refresh(),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: files.length,
              separatorBuilder: (_, _) => const Divider(
                height: 0.5,
                thickness: 0.5,
                color: Color(0xFFE4E4E4),
              ),
              itemBuilder: (_, i) => _FileTile(
                file: files[i],
                onTap: () => context.push(
                  '/session-diff-file/$agentId/$convId?idx=$i',
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  String _summary(List<SessionDiffFile> files) {
    final add = files.fold<int>(0, (a, f) => a + f.additions);
    final del = files.fold<int>(0, (a, f) => a + f.deletions);
    return '${files.length} 文件 · +$add −$del';
  }
}

class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (error is RpcException) {
      final code = (error as RpcException).code;
      if (code == -32601) {
        return const _EmptyView(
          icon: Icons.history,
          title: '暂无变更',
          subtitle: '发送首条消息后可查看',
          showRetry: false,
        );
      }
      if (code == -32001) {
        return _EmptyView(
          icon: Icons.cloud_off,
          title: 'Agent 离线',
          subtitle: '无法获取变更,请稍后重试',
          showRetry: true,
          onRetry: onRetry,
        );
      }
      if (code == -32002) {
        return _EmptyView(
          icon: Icons.timer,
          title: '加载超时',
          subtitle: '变更数据较大或网络较慢',
          showRetry: true,
          onRetry: onRetry,
        );
      }
      return _EmptyView(
        icon: Icons.error_outline,
        title: '加载失败',
        subtitle: (error as RpcException).message,
        showRetry: true,
        onRetry: onRetry,
      );
    }
    return _EmptyView(
      icon: Icons.error_outline,
      title: '加载失败',
      subtitle: error.toString(),
      showRetry: true,
      onRetry: onRetry,
    );
  }
}

class _EmptyView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool showRetry;
  final VoidCallback? onRetry;

  const _EmptyView({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.showRetry,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 36, color: const Color(0xFFCCCCCC)),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontSize: 14, color: Color(0xFF555555))),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
          ),
          if (showRetry && onRetry != null) ...[
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
        ],
      ),
    );
  }
}

class _FileTile extends StatelessWidget {
  final SessionDiffFile file;
  final VoidCallback onTap;

  const _FileTile({required this.file, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final status = file.status ?? 'modified';
    final isDeleted = status == 'deleted';
    final badgeColor = status == 'added'
        ? const Color(0xFF07C160)
        : (status == 'deleted' ? const Color(0xFFFA5151) : const Color(0xFFFA9D3B));
    final badgeText = status == 'added' ? 'A' : (status == 'deleted' ? 'D' : 'M');

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: Text(
                badgeText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                file.file ?? '(unknown)',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: isDeleted ? const Color(0xFF888888) : const Color(0xFF222222),
                  decoration: isDeleted ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '+${file.additions}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF07C160)),
            ),
            const SizedBox(width: 4),
            Text(
              '−${file.deletions}',
              style: const TextStyle(fontSize: 11, color: Color(0xFFFA5151)),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 14, color: Color(0xFF888888)),
          ],
        ),
      ),
    );
  }
}
