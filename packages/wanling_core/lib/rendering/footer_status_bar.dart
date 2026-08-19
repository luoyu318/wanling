import 'package:flutter/material.dart';

import 'package:wanling_core/widgets/chat/shimmer_text.dart';
import 'footer_info_bar.dart';

/// 聚合卡底部状态条:承接原顶栏 + busy 气泡的动态状态职责。
/// 同位置两种形态:
/// - generating: 动态阶段词(ShimmerText 闪烁),按聚合卡最后一个非 footer 元素推导
///   (思考中/执行中/汇总中),与 appbar「灵光涌动...」区分文案。
/// - done: 静态 FooterInfoBar(模式/时长/模型/tokens,来自 finished footer 快照)。
String aggregatePhaseText(List<Map<String, dynamic>> elements) {
  for (final e in elements.reversed) {
    if (e['type'] == 'footer') continue;
    switch (e['type']) {
      case 'reasoning':
        return '思考中...';
      case 'tool_card':
        return '执行中...';
      case 'markdown':
        return '汇总中...';
      default:
        return '思考中...';
    }
  }
  return '思考中...';
}

class FooterStatusBar extends StatelessWidget {
  final bool generating;
  final List<Map<String, dynamic>> elements;
  final Map<String, dynamic> footerData;
  const FooterStatusBar({
    super.key,
    required this.generating,
    required this.elements,
    required this.footerData,
  });

  @override
  Widget build(BuildContext context) {
    if (generating) {
      return Container(
        color: const Color(0xFFF7F7F7),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: ShimmerText(
          text: aggregatePhaseText(elements),
          baseColor: const Color(0xFF07C160),
          style: const TextStyle(fontSize: 11),
        ),
      );
    }
    return FooterInfoBar(data: footerData);
  }
}
