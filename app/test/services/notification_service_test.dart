import 'dart:typed_data';

import 'package:app/services/notification_service.dart';
import 'package:app/utils/notification_payload.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NotificationService 参数构造与计数前缀', () {
    test('NotificationPayload 构造与 agentName 取值', () {
      final payload = NotificationPayload(
        convId: 'conv-1',
        agentId: 'agent-1',
        agentName: '白羽',
      );
      expect(payload.agentName, '白羽');
    });

    test('ByteArrayAndroidIcon 接受 Uint8List bitmap', () {
      final avatarBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      final icon = ByteArrayAndroidIcon(avatarBytes);
      expect(icon, isNotNull);
    });

    test('Person.icon 接受 ByteArrayAndroidIcon', () {
      final avatarBytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);
      final person = Person(
        name: '白羽',
        icon: ByteArrayAndroidIcon(avatarBytes),
      );
      expect(person.name, '白羽');
      expect(person.icon, isNotNull);
    });

    test('Message 构造(text + timestamp + person)', () {
      final person = Person(name: '白羽');
      final msg = Message('你好', DateTime(2026, 6, 24), person);
      expect(msg.text, '你好');
    });

    test('MessagingStyleInformation 构造(person + messages)', () {
      final person = Person(name: '白羽');
      final style = MessagingStyleInformation(
        person,
        messages: [Message('你好', DateTime.now(), person)],
      );
      expect(style, isNotNull);
    });

    test('body 计数前缀 — unreadCount>1 时加 [N条]', () {
      // 复用 notification_service 的静态方法验证计数前缀逻辑
      expect(NotificationService.prefixCount(1, '你好'), '你好');
      expect(NotificationService.prefixCount(2, '你好'), '[2条] 你好');
      expect(NotificationService.prefixCount(5, '在吗'), '[5条] 在吗');
    });
  });
}
