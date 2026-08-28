import 'package:flutter/material.dart';

import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'message_bubble.dart';

/// mixed(图文混合)渲染:拆「图片气泡+文字气泡」两个连续气泡。
/// wrapInBubble=false:双气泡各自包 BubbleWithTail,外层不再包壳。
/// 文本取顶层 data.text(发送合同,dsh 桥同款);items 中图片条目复用
/// image renderer 渲染(取首条;协议数组天然支持多图,渲染逐条循环即可)。
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          rc.isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        for (final fileId in imageIds)
          BubbleWithTail(
            isMe: rc.isMe,
            child: imageRenderer.build(context, {
              'msg_type': 'image',
              'data': {'file_id': fileId},
            }, rc),
          ),
        if (text.isNotEmpty)
          BubbleWithTail(
            isMe: rc.isMe,
            child: const TextContentRenderer().build(context, {
              'msg_type': 'text',
              'data': {'text': text},
            }, rc),
          ),
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
