import 'package:flutter/widgets.dart';

/// 流式文本渲染。
///
/// 流式期间(isStreaming=true)整段文本走一次 [mdBuilder] 渲染,不拆分
/// settled/tail、不加渐显动画。原因:任何「先增量再补全」的拆分都会让
/// markdown 语法跨边界断裂(如 `**加` 在 settled、`粗**abc` 在 tail),
/// 未闭合段必然以源码示人 → 源码与富文本形态突变 + 上下抖动。
///
/// 整段统一解析:语法跨 delta 始终完整,高度随文本线性增长,与主流 IM 一致。
/// 未闭合语法(如流式到 `#`)在过渡帧由解析器降级为普通文本,闭合后自然变标题。
///
/// [text] 当前累积的完整文本。
/// [mdBuilder] markdown 渲染函数(流式 + 终态共用,保证形态一致)。
/// [streaming] 是否仍在流式输出中。false 时同样走 mdBuilder(无差异)。
class StreamingText extends StatelessWidget {
  final String text;
  final Widget Function(String) mdBuilder;
  final bool streaming;

  const StreamingText({
    super.key,
    required this.text,
    required this.mdBuilder,
    required this.streaming,
  });

  @override
  Widget build(BuildContext context) {
    return mdBuilder(text);
  }
}
