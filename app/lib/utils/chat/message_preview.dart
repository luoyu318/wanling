import 'package:flutter/widgets.dart';

import '../../models/message.dart';

/// 提取消息纯文本(支持 text / markdown msg_type)。
String extractMessageText(ChatMessage msg) {
  final data = msg.content['data'] as Map<String, dynamic>?;
  return (data?['text'] as String?) ?? '';
}

/// 客户端预提取引用 preview(与 server extractPreview 同规则)。
/// 
/// - text / markdown:换行折叠为空格,截 50 字符(rune-aware via .characters)
/// - markdown 额外剥 * _ ` ~ | 简化符号
/// - image / file / mixed / card / 其他:占位文案
String extractLocalPreview(ChatMessage m) {
  final data = m.content['data'] as Map<String, dynamic>?;
  final msgType = m.content['msg_type'] ?? 'text';
  switch (msgType) {
    case 'text':
      final t = (data?['text'] as String?) ?? '';
      final folded = t.replaceAll('\n', ' ');
      return folded.characters.take(50).toString();
    case 'markdown':
      final md = (data?['text'] as String?) ?? '';
      final stripped = md.replaceAll(RegExp(r'[`*_~|]'), '');
      return stripped.replaceAll('\n', ' ').characters.take(50).toString();
    case 'image':
      return '[图片]';
    case 'file':
      return '[文件] ${data?['file_name'] ?? ''}';
    case 'mixed':
      final t = (data?['text'] as String?) ?? '';
      if (t.isEmpty) return '[图文]';
      return t.replaceAll('\n', ' ').characters.take(50).toString();
    case 'card':
      return '[卡片] ${data?['title'] ?? ''}';
    case 'step_finish':
      return '[完成]';
    default:
      return '[消息]';
  }
}
