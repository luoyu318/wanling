import 'package:flutter/material.dart';

import 'message_content_renderer.dart';

/// 推理步结束的元信息行：耗时 | tokens | cost。
/// 最轻量渲染器，无卡片容器。
class StepFinishRenderer implements MessageContentRenderer {
  const StepFinishRenderer();

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(BuildContext context, Map<String, dynamic> content, MessageRenderContext rc) {
    final data = content['data'] as Map<String, dynamic>? ?? {};

    // finished=true: 主 session agent 循环结束汇总条(silent=false 触发响铃 + 未读计数)。
    // 仅显示 tokens 统计,外间距 0(由 MessageRow 外层 padding 统一控制行间距)。
    final finished = data['finished'] == true;
    if (finished) {
      final tokens = data['tokens'];
      if (tokens is! Map) return const SizedBox.shrink();
      final totalTokens = tokens['total'];
      if (totalTokens is! num || totalTokens <= 0) {
        return const SizedBox.shrink();
      }

      return Padding(
        padding: EdgeInsets.zero,
        child: Text(
          'tokens ${(totalTokens / 1000).toStringAsFixed(1)}k',
          style: const TextStyle(fontSize: 11, color: Color(0xFFBBBBBB)),
        ),
      );
    }

    final parts = <String>[];

    final duration = data['duration'];
    if (duration is num && duration > 0) {
      parts.add('⏱ ${duration.toStringAsFixed(1)}s');
    }

    final tokens = data['tokens'];
    if (tokens is Map) {
      final totalTokens = tokens['total'];
      if (totalTokens is num && totalTokens > 0) {
        parts.add('tokens ${(totalTokens / 1000).toStringAsFixed(1)}k');
      }
    }

    final cost = data['cost'];
    if (cost is num && cost > 0) {
      parts.add('\$${cost.toStringAsFixed(3)}');
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (int i = 0; i < parts.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Text('|', style: TextStyle(fontSize: 11, color: Color(0xFFE4E4E4))),
              ),
            Text(parts[i], style: const TextStyle(fontSize: 11, color: Color(0xFFBBBBBB))),
          ],
        ],
      ),
    );
  }
}
