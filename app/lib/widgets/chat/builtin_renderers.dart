import 'package:flutter/material.dart';

import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'message_bubble.dart';

/// mixed(图文混合)渲染:拆「裸图+文字气泡」连续渲染。
/// wrapInBubble=false:图片条目走裸图(同普通图片消息,带 Hero/画廊),
/// 文本条目包 BubbleWithTail,外层不再包壳。
/// 条目间距对齐相邻两条普通消息(各行 outerPadding vertical:8 → 16)。
/// 文本取顶层 data.text(发送合同,dsh 桥同款);items 中图片条目复用
/// image renderer 渲染(协议数组天然支持多图,渲染逐条循环即可)。
class MixedContentRenderer implements MessageContentRenderer {
  const MixedContentRenderer();

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = (content['data'] ?? {}) as Map<String, dynamic>;
    final items = (data['items'] as List?) ?? const [];
    final imageIds = items
        .whereType<Map>()
        .where((e) => e['type'] == 'image')
        .map((e) => e['file_id'])
        .whereType<String>()
        .toList();
    final text = (data['text'] as String?) ?? '';

    const imageRenderer = ImageContentRenderer();
    final children = <Widget>[
      for (final fileId in imageIds)
        imageRenderer.build(context, {
          'msg_type': 'image',
          'data': {'file_id': fileId},
        }, rc),
      if (text.isNotEmpty)
        BubbleWithTail(
          isMe: rc.isMe,
          child: const TextContentRenderer().build(context, {
            'msg_type': 'text',
            'data': {'text': text},
          }, rc),
        ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          rc.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        for (final (i, child) in children.indexed) ...[
          if (i > 0) const SizedBox(height: 16),
          child,
        ],
      ],
    );
  }
}

/// 注册 mixed 内容渲染器。APP 启动时在 registerBuiltinRenderers() 之后调用
/// （mixed 的双气泡壳 BubbleWithTail 依赖 app 侧 message_bubble.dart，
/// 故 MixedContentRenderer 定义与注册点均在 app 侧，不进 wanling_core）。
void registerMixedContentRenderer() {
  ContentRendererRegistry.register(MsgType.mixed, const MixedContentRenderer());
}
