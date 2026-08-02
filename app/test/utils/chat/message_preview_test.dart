// app/test/utils/chat/message_preview_test.dart
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/models/message.dart';
import 'package:app/utils/chat/message_preview.dart';

ChatMessage mkMsg({
  required String msgType,
  Map<String, dynamic>? data,
}) {
  final content = <String, dynamic>{'msg_type': msgType};
  if (data != null) content['data'] = data;
  return ChatMessage(
    id: 'm1',
    conversationId: 'c1',
    senderType: 'user',
    senderId: 'u1',
    content: content,
    createdAt: DateTime.parse('2026-07-01T10:00:00Z'),
  );
}

void main() {
  group('extractMessageText', () {
    test('text 类型返回 data.text', () {
      final m = mkMsg(msgType: 'text', data: {'text': 'hello'});
      expect(extractMessageText(m), 'hello');
    });

    test('无 data 返回空串', () {
      final m = mkMsg(msgType: 'text');
      expect(extractMessageText(m), '');
    });
  });

  group('extractLocalPreview', () {
    test('text 换行折叠为空格 + 截 50 字符', () {
      final long = 'a' * 60;
      final m = mkMsg(msgType: 'text', data: {'text': 'line1\nline2\n$long'});
      final result = extractLocalPreview(m);
      expect(result.contains('\n'), isFalse);
      expect(result.characters.length, lessThanOrEqualTo(50));
    });

    test('markdown 剥离 * _ ` ~ | 符号', () {
      final m = mkMsg(msgType: 'markdown', data: {'text': '**bold** _it_'});
      final result = extractLocalPreview(m);
      expect(result.contains('*'), isFalse);
      expect(result.contains('_'), isFalse);
    });

    test('image 返回 [图片]', () {
      expect(extractLocalPreview(mkMsg(msgType: 'image')), '[图片]');
    });

    test('file 返回 [文件] + file_name', () {
      final m = mkMsg(msgType: 'file', data: {'file_name': 'doc.pdf'});
      expect(extractLocalPreview(m), '[文件] doc.pdf');
    });

    test('mixed 空文本返回 [图文]', () {
      expect(extractLocalPreview(mkMsg(msgType: 'mixed')), '[图文]');
    });

    test('mixed 有文本折叠换行截 50', () {
      final m = mkMsg(msgType: 'mixed', data: {'text': 'a\nb'});
      expect(extractLocalPreview(m), 'a b');
    });

    test('card 返回 [卡片] + title', () {
      final m = mkMsg(msgType: 'card', data: {'title': '审批'});
      expect(extractLocalPreview(m), '[卡片] 审批');
    });

    test('未知 msg_type 返回 [消息]', () {
      expect(extractLocalPreview(mkMsg(msgType: 'unknown')), '[消息]');
    });
  });
}
