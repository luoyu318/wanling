import 'dart:typed_data';

import 'package:wanling_core/services/notification_service.dart';
import 'package:wanling_core/utils/notification_payload.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationService 参数构造与计数前缀', () {
    test('NotificationPayload 构造与 agentName 取值', () {
      const payload = NotificationPayload(
        convId: 'conv-1',
        agentId: 'agent-1',
        agentName: '白羽',
      );
      expect(payload.agentName, '白羽');
    });

    test('ByteArrayAndroidBitmap 接受 Uint8List bitmap', () {
      final avatarBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      final bitmap = ByteArrayAndroidBitmap(avatarBytes);
      expect(bitmap, isNotNull);
    });

    test('body 格式 — N>1 时 [N条]消息', () {
      expect(NotificationService.prefixBody(1, '你好'), '你好');
      expect(NotificationService.prefixBody(2, '你好'), '[2条]你好');
      expect(NotificationService.prefixBody(5, '在吗'), '[5条]在吗');
    });
  });
}
