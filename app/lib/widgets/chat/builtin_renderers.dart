import 'package:flutter/material.dart';

import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'message_bubble.dart';

/// mixed(图文/文件混合)渲染:拆「裸图/文件卡+文字气泡」连续渲染。
/// wrapInBubble=false:图片条目走裸图(同普通图片消息,带 Hero/画廊),
/// file 条目走文件卡(复用 FileContentRenderer,元信息从 item 取——server
/// 不富化 mixed items),文本条目包 BubbleWithTail,外层不再包壳。
/// 条目间距对齐相邻两条普通消息(各行 outerPadding vertical:8 → 16)。
/// 文本取顶层 data.text(发送合同,dsh 桥同款);items 按协议顺序逐条渲染,
/// 未知类型条目静默跳过(防御,协议违约不崩渲染)。
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
    final text = (data['text'] as String?) ?? '';

    const imageRenderer = ImageContentRenderer();
    const fileRenderer = FileContentRenderer();
    final children = <Widget>[
      for (final item in items.whereType<Map>())
        if (item['type'] == 'image' && item['file_id'] is String)
          imageRenderer.build(context, {
            'msg_type': 'image',
            'data': {'file_id': item['file_id']},
          }, rc)
        else if (item['type'] == 'file' && item['file_id'] is String)
          fileRenderer.build(context, {
            'msg_type': 'file',
            'data': {
              'file_id': item['file_id'],
              if (item['filename'] is String) 'filename': item['filename'],
              if (item['mime_type'] is String) 'mime_type': item['mime_type'],
              if (item['file_size'] is int) 'file_size': item['file_size'],
            },
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
