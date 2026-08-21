import 'package:flutter/material.dart';
import 'package:wanling_core/utils/mono_font.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/session_diff.dart';
import 'package:wanling_core/providers/session_diff_provider.dart';
import 'package:wanling_core/services/api_service.dart' show RpcException;

/// 详情侧栏「变更」tab:core sessionDiffProvider((agentId, convId)) 驱动。
///
/// 文件列表(状态徽标 A/M/D + binary/truncated 标记 + +/- 计数)+
/// 点击展开内嵌 patch 视图(等宽字体 +/- 行着色,不引三方组件)。
/// binary 文件显示「二进制文件」占位;truncated 显示「已截断,共 N 行」
/// 提示(session.diff 防护协议的桌面消费端)。
class DetailChangesTab extends ConsumerWidget {
  final String convId;
  final String? agentId;

  const DetailChangesTab({super.key, required this.convId, this.agentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // agentId 缺失(sessionDiff key 必填):fail fast 提示,不发请求
    if (agentId == null || agentId!.isEmpty) {
      return const _HintView(
        icon: Icons.info_outline,
        title: '无法获取变更',
        subtitle: '会话缺少 Agent 信息',
      );
    }
    final key = (agentId: agentId!, convId: convId);
    final state = ref.watch(sessionDiffProvider(key));
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 摘要行:N 文件 · +a −d + 刷新
        Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: state.maybeWhen(
                  data: (files) => Text(
                    _summary(files),
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                  orElse: () => const SizedBox.shrink(),
                ),
              ),
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton(
                  tooltip: '刷新',
                  padding: EdgeInsets.zero,
                  iconSize: 15,
                  icon: Icon(
                    Icons.refresh,
                    color: scheme.onSurface.withValues(alpha: 0.55),
                  ),
                  onPressed: () =>
                      ref.read(sessionDiffProvider(key).notifier).refresh(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: state.when(
            loading: () => const Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
            error: (err, _) => _ErrorView(
              error: err,
              onRetry: () =>
                  ref.read(sessionDiffProvider(key).notifier).load(),
            ),
            data: (files) {
              if (files.isEmpty) {
                return const _HintView(
                  icon: Icons.history,
                  title: '暂无变更',
                  subtitle: '本次会话尚未产生代码变更',
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 8),
                itemCount: files.length,
                itemBuilder: (_, i) => _FileTile(file: files[i]),
              );
            },
          ),
        ),
      ],
    );
  }

  String _summary(List<SessionDiffFile> files) {
    final add = files.fold<int>(0, (a, f) => a + f.additions);
    final del = files.fold<int>(0, (a, f) => a + f.deletions);
    return '${files.length} 文件 · +$add −$del';
  }
}

/// 错误视图:RpcException code 语义映射(对齐 APP 端 session_diff_page)。
class _ErrorView extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (error is RpcException) {
      final code = (error as RpcException).code;
      if (code == -32601) {
        return const _HintView(
          icon: Icons.history,
          title: '暂无变更',
          subtitle: '发送首条消息后可查看',
        );
      }
      if (code == -32001) {
        return const _HintView(
          icon: Icons.cloud_off,
          title: 'Agent 离线',
          subtitle: '无法获取变更,请稍后重试',
          showRetry: true,
        );
      }
      if (code == -32002) {
        return const _HintView(
          icon: Icons.timer,
          title: '加载超时',
          subtitle: '变更数据较大或网络较慢',
          showRetry: true,
        );
      }
      return _HintView(
        icon: Icons.error_outline,
        title: '加载失败',
        subtitle: (error as RpcException).message,
        showRetry: true,
        onRetry: onRetry,
      );
    }
    return _HintView(
      icon: Icons.error_outline,
      title: '加载失败',
      subtitle: error.toString(),
      showRetry: true,
      onRetry: onRetry,
    );
  }
}

/// 居中提示视图(空态/错误态/缺 agentId)。
class _HintView extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool showRetry;
  final VoidCallback? onRetry;

  const _HintView({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.showRetry = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 34, color: scheme.onSurface.withValues(alpha: 0.25)),
          const SizedBox(height: 10),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
          if (showRetry && onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('重试', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单文件条目:ExpansionTile 展开内嵌 patch 视图。
class _FileTile extends StatelessWidget {
  final SessionDiffFile file;

  const _FileTile({required this.file});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = file.status ?? 'modified';
    final badgeColor = status == 'added'
        ? const Color(0xFF07C160)
        : (status == 'deleted'
            ? const Color(0xFFFA5151)
            : const Color(0xFFFA9D3B));
    final badgeText =
        status == 'added' ? 'A' : (status == 'deleted' ? 'D' : 'M');

    return ExpansionTile(
      key: ValueKey('diff_file_${file.file}'),
      dense: true,
      visualDensity: VisualDensity.compact,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      childrenPadding: EdgeInsets.zero,
      title: Row(
        children: [
          Container(
            width: 18,
            height: 18,
            decoration:
                BoxDecoration(color: badgeColor, shape: BoxShape.circle),
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
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              file.file ?? '(unknown)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'monospace', fontFamilyFallback: kMonoFontFallback,
                fontSize: 12,
                color: scheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ),
          const SizedBox(width: 6),
          if (file.binary)
            const _Marker(text: '二进制', color: Color(0xFF8A8F99)),
          if (file.truncated)
            const _Marker(text: '已截断', color: Color(0xFFE6A23C)),
          const SizedBox(width: 4),
          Text(
            '+${file.additions}',
            style:
                const TextStyle(fontSize: 11, color: Color(0xFF07C160)),
          ),
          const SizedBox(width: 3),
          Text(
            '−${file.deletions}',
            style: const TextStyle(fontSize: 11, color: Color(0xFFFA5151)),
          ),
        ],
      ),
      children: [
        if (file.binary)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                '二进制文件',
                style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
              ),
            ),
          )
        else ...[
          if (file.truncated) _TruncatedHint(patch: file.patch ?? ''),
          DiffPatchView(patch: file.patch ?? ''),
        ],
      ],
    );
  }
}

/// 状态标记小徽章(二进制/已截断)。
class _Marker extends StatelessWidget {
  final String text;
  final Color color;

  const _Marker({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 2),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 9, color: color),
      ),
    );
  }
}

/// 截断提示行:patch 非空给接收行数,空 patch(帧预算清空)只给截断提示。
class _TruncatedHint extends StatelessWidget {
  final String patch;

  const _TruncatedHint({required this.patch});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final trimmed = patch.trimRight();
    final label = trimmed.isEmpty ? '已截断' : '已截断，共 ${trimmed.split('\n').length} 行';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          const Icon(Icons.content_cut, size: 12, color: Color(0xFFE6A23C)),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: Color(0xFFE6A23C)),
          ),
        ],
      ),
    );
  }
}

// === patch 视图(等宽 +/- 行着色,双轴滚动,不引三方组件) ===

enum _DiffLineKind { context, addition, deletion, hunkHeader }

class _DiffLine {
  final String text;
  final _DiffLineKind kind;

  const _DiffLine(this.text, this.kind);
}

List<_DiffLine> _parsePatch(String patch) {
  if (patch.isEmpty) return const [];
  final result = <_DiffLine>[];
  for (final raw in patch.split('\n')) {
    if (raw.isEmpty) continue;
    if (raw.startsWith('@@')) {
      result.add(_DiffLine(raw, _DiffLineKind.hunkHeader));
    } else if (raw.startsWith('+')) {
      result.add(_DiffLine(raw, _DiffLineKind.addition));
    } else if (raw.startsWith('-')) {
      result.add(_DiffLine(raw, _DiffLineKind.deletion));
    } else {
      result.add(_DiffLine(raw, _DiffLineKind.context));
    }
  }
  return result;
}

/// patch 滚动视图:纵向 + 横向双轴滚动(长行不折行),行背景/前景按
/// +/- 着色,亮度自适应(桌面深浅双主题)。
class DiffPatchView extends StatelessWidget {
  final String patch;

  const DiffPatchView({super.key, required this.patch});

  @override
  Widget build(BuildContext context) {
    final lines = _parsePatch(patch);
    if (lines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            '无变更内容',
            style: TextStyle(fontSize: 12, color: Color(0xFF888888)),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final line in lines) _DiffLineRow(line: line)],
        ),
      ),
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  final _DiffLine line;

  const _DiffLineRow({required this.line});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final kind = line.kind;
    final Color bg;
    final Color fg;
    switch (kind) {
      case _DiffLineKind.addition:
        bg = dark ? const Color(0xFF143324) : const Color(0xFFE6F7EC);
        fg = dark ? const Color(0xFF7BD88F) : const Color(0xFF074D2C);
      case _DiffLineKind.deletion:
        bg = dark ? const Color(0xFF3A1D1D) : const Color(0xFFFDECEC);
        fg = dark ? const Color(0xFFE58888) : const Color(0xFF8B1F1F);
      case _DiffLineKind.hunkHeader:
        bg = Colors.transparent;
        fg = dark ? const Color(0xFF888888) : const Color(0xFF888888);
      case _DiffLineKind.context:
        bg = Colors.transparent;
        fg = dark ? const Color(0xFFBBBBBB) : const Color(0xFF555555);
    }
    // 横向滚动轴宽度无限,行取自然宽(不可用 minWidth:infinity);
    // +/- 行背景随文本宽,长行靠横向滚动查看
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0.5),
      child: Text(
        line.text,
        softWrap: false,
        style: TextStyle(fontFamily: 'monospace', fontFamilyFallback: kMonoFontFallback, fontSize: 11, color: fg),
      ),
    );
  }
}
