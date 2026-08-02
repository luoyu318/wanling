import 'package:flutter/material.dart';

/// agent_session 输入框下方的环境信息条:
/// 「📁 basename(cwd) · ⎇ branch · {contextUsed} · {pct}%」
/// cwd 为空(null)整行不渲染;gitBranch 为空只渲染 cwd 段;
/// contextUsed 为空或 0(旧 session_meta 兼容)不渲染 token 段。
class EnvMetaStrip extends StatelessWidget {
  final String? cwd;
  final String? gitBranch;

  /// 会话累计 token 总数。仅作数据透传,不再渲染(预留 settings 页查看累计成本)。
  final int? tokensTotal;

  /// 当前上下文窗口已用 token 数(null/0 → 不渲染 token 段)。渲染为主数字。
  final int? contextUsed;

  /// 模型上下文上限(0/null → model 未在缓存,只显示 used 不显示百分比)。
  final int? contextLimit;

  /// cwd 段点击回调。非 null 时 cwd 段(图标+文字)整体变蓝,表示可点击。
  /// 调用方负责 convType 判断(仅 agent_session 才传)。
  final VoidCallback? onTapCwd;

  /// gitBranch 段点击回调。非 null 时 gitBranch 段(图标+文字)整体变蓝,表示可点击。
  /// 调用方负责 convType 判断(仅 agent_session 才传)。
  final VoidCallback? onTapGitBranch;

  const EnvMetaStrip({
    super.key,
    required this.cwd,
    this.gitBranch,
    this.tokensTotal,
    this.contextUsed,
    this.contextLimit,
    this.onTapCwd,
    this.onTapGitBranch,
  });

  @override
  Widget build(BuildContext context) {
    if (cwd == null || cwd!.isEmpty) return const SizedBox.shrink();

    final basename = _basename(cwd!);
    final parts = <InlineSpan>[];

    // cwd 段:onTapCwd != null 时整体变蓝,可点击。
    final cwdClickable = onTapCwd != null;
    final cwdColor = cwdClickable
        ? const Color(0xFF5B7CFA)
        : const Color(0xFF999999);
    final cwdIconColor = cwdClickable
        ? const Color(0xFF5B7CFA)
        : const Color(0xFF999999);
    final cwdSpans = <InlineSpan>[
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child:
            Icon(Icons.folder_outlined, size: 12, color: cwdIconColor),
      ),
      const TextSpan(text: ' '),
      TextSpan(
        text: basename,
        style: TextStyle(fontSize: 11, color: cwdColor),
      ),
    ];
    if (cwdClickable) {
      parts.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTapCwd,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text.rich(TextSpan(children: cwdSpans)),
            ],
          ),
        ),
      ));
    } else {
      parts.addAll(cwdSpans);
    }

    if (gitBranch != null && gitBranch!.isNotEmpty) {
      parts.add(const TextSpan(
        text: ' · ',
        style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB)),
      ));
      // gitBranch 段:onTapGitBranch != null 时整体变蓝,可点击。
      final branchClickable = onTapGitBranch != null;
      final branchColor = branchClickable
          ? const Color(0xFF5B7CFA)
          : const Color(0xFF999999);
      final branchSpans = <InlineSpan>[
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Icon(Icons.call_split, size: 12, color: branchColor),
        ),
        const TextSpan(text: ' '),
        TextSpan(
          text: gitBranch,
          style: TextStyle(fontSize: 11, color: branchColor),
        ),
      ];
      if (branchClickable) {
        parts.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTapGitBranch,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(TextSpan(children: branchSpans)),
              ],
            ),
          ),
        ));
      } else {
        parts.addAll(branchSpans);
      }
    }

    // token 段:contextUsed > 0 才渲染。
    // 显示当前上下文窗口占用(非累计 token),与用户对「上下文还剩多少」的心智模型对齐。
    final used = contextUsed ?? 0;
    final limit = contextLimit ?? 0;
    if (used > 0) {
      parts.add(const TextSpan(
        text: ' · ',
        style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB)),
      ));
      parts.add(TextSpan(
        text: _formatTokens(used),
        style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
      ));
      // 百分比段:limit > 0 才渲染(model 未在缓存时 limit=0 跳过)。
      if (limit > 0) {
        final pct = (used / limit * 100).round().clamp(0, 999);
        parts.add(const TextSpan(
          text: ' · ',
          style: TextStyle(fontSize: 11, color: Color(0xFFBBBBBB)),
        ));
        parts.add(TextSpan(
          text: '$pct%',
          style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
        ));
      }
    }

    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
      child: Text.rich(
        TextSpan(children: parts),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  String _basename(String path) {
    final i = path.lastIndexOf('/');
    return i >= 0 && i < path.length - 1 ? path.substring(i + 1) : path;
  }

  /// token 数格式化:< 1000 原值;≥1000 用 k 1 位小数;≥1M 用 M 1 位小数。
  /// 整数位时省略 .0(5.0k → 5k),与渲染规则示例一致。
  String _formatTokens(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      return '${_stripTrailingZero((n / 1000).toStringAsFixed(1))}k';
    }
    return '${_stripTrailingZero((n / 1000000).toStringAsFixed(1))}M';
  }

  String _stripTrailingZero(String s) =>
      s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
