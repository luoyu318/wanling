import 'package:flutter/material.dart';

import 'package:wanling_core/utils/duration_format.dart';

/// 聚合卡底部提示条:回合结束(卡 state=done + finished footer)时渲染。
/// 独立组件,浅灰底通栏,左侧 模式+时长,右侧 模型+tokens。
/// 数据全部来自 footer 元素 data(消息快照,非 sessionMeta 实时态)。
class FooterInfoBar extends StatelessWidget {
  final Map<String, dynamic> data;
  const FooterInfoBar({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    // 主动停止态(plugin finishCard("stop")):显示「已停止」,不渲染四要素。
    // 无终态 tokens/duration/mode/model 数据(footer 只带 reason/stopped/finished)。
    if (data['stopped'] == true) {
      return Container(
        color: const Color(0xFFF7F7F7),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: const Row(
          children: [
            Text('已停止',
                style: TextStyle(fontSize: 11, color: Color(0xFF999999))),
          ],
        ),
      );
    }
    final mode = (data['mode'] as String?) ?? '';
    final model = (data['model'] as String?) ?? '';
    final duration = data['duration'];
    // duration 毫秒(plugin finalizeCard 传 completed - user.created,对齐 TUI)。
    // 用 Locale.duration 格式化:<1000ms →「22ms」,<60s →「1.6s」,更长为「1m 30s」。
    final durationText = duration is num && duration > 0
        ? formatDurationMs(duration.toInt())
        : '';
    final tokens = data['tokens'];
    final total = tokens is Map ? tokens['total'] : null;
    final tokensText = total is num && total > 0
        ? '${(total / 1000).toStringAsFixed(1)}k'
        : '';

    // 四要素全空(历史消息 footer 无 mode/duration/model/tokens 快照):不渲染空通栏。
    if (mode.isEmpty &&
        durationText.isEmpty &&
        model.isEmpty &&
        tokensText.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      // 顶部细线分隔,与正文区分离(替代整圈边框)
      decoration: const BoxDecoration(
        color: Color(0xFFF7F7F7),
        border: Border(top: BorderSide(color: Color(0xFFF0F0F0))),
      ),
      child: Row(
        children: [
          if (mode.isNotEmpty) ...[
            Text(mode,
                style: const TextStyle(fontSize: 11, color: Color(0xFF666666))),
          ],
          if (durationText.isNotEmpty) ...[
            if (mode.isNotEmpty) const SizedBox(width: 10),
            Text(durationText,
                style: const TextStyle(fontSize: 11, color: Color(0xFF07C160))),
          ],
          const Spacer(),
          if (model.isNotEmpty)
            Text(model,
                style: const TextStyle(fontSize: 11, color: Color(0xFF5B8BF7))),
          if (tokensText.isNotEmpty) ...[
            if (model.isNotEmpty) const SizedBox(width: 10),
            Text('tokens $tokensText',
                style: const TextStyle(fontSize: 11, color: Color(0xFFFA8C16))),
          ],
        ],
      ),
    );
  }
}
