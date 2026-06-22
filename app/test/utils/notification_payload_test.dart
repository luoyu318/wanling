import 'package:flutter_test/flutter_test.dart';
import 'package:app/utils/notification_payload.dart';

void main() {
  group('NotificationPayload', () {
    test('toJson + fromJson 往返', () {
      final p = NotificationPayload(convId: 'c1', agentId: 'a1', agentName: '黑羽');
      final json = p.toJson();
      final restored = NotificationPayload.fromJson(json);
      expect(restored.convId, 'c1');
      expect(restored.agentId, 'a1');
      expect(restored.agentName, '黑羽');
    });

    test('fromJson 兼容字符串 payload', () {
      final json = '{"convId":"c2","agentId":"a2","agentName":"白羽"}';
      final restored = NotificationPayload.fromJsonString(json);
      expect(restored!.agentName, '白羽');
    });

    test('fromJsonString 非法 JSON 返回 null', () {
      expect(NotificationPayload.fromJsonString('not json'), isNull);
    });

    test('fromJsonString 缺字段返回 null', () {
      expect(
        NotificationPayload.fromJsonString('{"convId":"c1"}'),
        isNull,
      );
    });
  });

  group('messagePreview', () {
    test('text 取纯文本前 50 字符', () {
      final preview = messagePreview(msgType: 'text', data: {'text': '你好世界'});
      expect(preview, '你好世界');
    });

    test('text 超长截断 50 字符', () {
      final long = 'a' * 100;
      final preview = messagePreview(msgType: 'text', data: {'text': long});
      expect(preview.length, 50);
    });

    test('markdown 取 data.text 前 50 字符', () {
      final preview = messagePreview(
        msgType: 'markdown',
        data: {'text': '# 标题\n\n正文内容'},
      );
      expect(preview.contains('正文内容'), isTrue);
    });

    test('image 显示 [图片]', () {
      expect(messagePreview(msgType: 'image', data: {}), '[图片]');
    });

    test('file 显示 [文件] 文件名', () {
      final preview = messagePreview(
        msgType: 'file',
        data: {'filename': 'report.pdf'},
      );
      expect(preview, '[文件] report.pdf');
    });

    test('file 缺文件名只显示 [文件]', () {
      expect(messagePreview(msgType: 'file', data: {}), '[文件]');
    });

    test('未知 msg_type 兜底 [新消息]', () {
      expect(messagePreview(msgType: 'unknown', data: {}), '[新消息]');
    });

    test('data 为 null 兜底', () {
      expect(messagePreview(msgType: 'text', data: null), '[新消息]');
    });
  });
}
