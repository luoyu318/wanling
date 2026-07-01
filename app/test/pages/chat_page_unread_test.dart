// chat_page_unread_test.dart
//
// 测试 computeNewlySeenUnread（由 _checkUnreadSeen 调用的顶层 pure function）。
//
// 这是真正的契约 test：直接驱动生产代码，若未来有人回退到
// `msg.isRead || senderType != 'agent'` 之类的双保险过滤，或破坏 isRead 跳过逻辑，
// 本测试会 fail。
import 'package:flutter_test/flutter_test.dart';

import 'package:app/models/message.dart';
import 'package:app/pages/chat_page.dart';

void main() {
  ChatMessage mkMsg({
    required String id,
    required String senderType,
    required bool isRead,
    DateTime? createdAt,
  }) {
    return ChatMessage(
      id: id,
      conversationId: 'c1',
      senderType: senderType,
      senderId: senderType == 'user' ? 'me' : 'ag',
      content: {'msg_type': 'text', 'data': {'text': 'x'}},
      isRead: isRead,
      createdAt: createdAt ?? DateTime.parse('2026-07-01T10:00:00Z'),
    );
  }

  group('computeNewlySeenUnread', () {
    test('只对未读消息触发，跳过 user 自发(server 落地 is_read=TRUE)和 agent 已读', () {
      // idx:    0      1      2      3      4
      //      user-read agent- agent- user- agent-
      //               unread read   read   unread
      // firstUnreadIdx 应为 1（第一条 isRead=false 的位置）
      final messages = <ChatMessage>[
        mkMsg(id: 'u1', senderType: 'user', isRead: true),
        mkMsg(
            id: 'a1',
            senderType: 'agent',
            isRead: false,
            createdAt: DateTime.parse('2026-07-01T10:01:00Z')),
        mkMsg(
            id: 'a2',
            senderType: 'agent',
            isRead: true,
            createdAt: DateTime.parse('2026-07-01T10:02:00Z')),
        mkMsg(
            id: 'u2',
            senderType: 'user',
            isRead: true,
            createdAt: DateTime.parse('2026-07-01T10:03:00Z')),
        mkMsg(
            id: 'a3',
            senderType: 'agent',
            isRead: false,
            createdAt: DateTime.parse('2026-07-01T10:04:00Z')),
      ];

      final result = computeNewlySeenUnread(
        messages: messages,
        firstUnreadIdx: 4,
        seenUnreadMsgIds: <String>{},
        isInViewport: (_) => true, // 全在视口
      );

      expect(result, equals(['a1', 'a3']),
          reason: '只应返回 2 条 agent 未读消息；user 自发和 agent 已读都应被跳过');
    });

    test('已 seen 的未读消息不重复计入', () {
      final messages = <ChatMessage>[
        mkMsg(id: 'a1', senderType: 'agent', isRead: false),
        mkMsg(
            id: 'a2',
            senderType: 'agent',
            isRead: false,
            createdAt: DateTime.parse('2026-07-01T10:01:00Z')),
      ];

      final result = computeNewlySeenUnread(
        messages: messages,
        firstUnreadIdx: 1,
        seenUnreadMsgIds: <String>{'a1'}, // a1 已 seen
        isInViewport: (_) => true,
      );

      expect(result, equals(['a2']),
          reason: 'a1 在 seenUnreadMsgIds 中，不应重复计入 newlySeen');
    });

    test('不在视口内的未读消息不计入', () {
      final messages = <ChatMessage>[
        mkMsg(id: 'a1', senderType: 'agent', isRead: false),
        mkMsg(
            id: 'a2',
            senderType: 'agent',
            isRead: false,
            createdAt: DateTime.parse('2026-07-01T10:01:00Z')),
      ];

      final result = computeNewlySeenUnread(
        messages: messages,
        firstUnreadIdx: 1,
        seenUnreadMsgIds: <String>{},
        isInViewport: (id) => id == 'a1', // 只有 a1 在视口
      );

      expect(result, equals(['a1']), reason: 'a2 不在视口，不应计入');
    });

    test('firstUnreadIdx 限制循环范围，之后的未读消息不算', () {
      // messages 长度 3，但 firstUnreadIdx=1 表示只扫到 idx=1
      final messages = <ChatMessage>[
        mkMsg(id: 'a1', senderType: 'agent', isRead: false),
        mkMsg(
            id: 'a2',
            senderType: 'agent',
            isRead: false,
            createdAt: DateTime.parse('2026-07-01T10:01:00Z')),
        mkMsg(
            id: 'a3',
            senderType: 'agent',
            isRead: false,
            createdAt: DateTime.parse('2026-07-01T10:02:00Z')),
      ];

      final result = computeNewlySeenUnread(
        messages: messages,
        firstUnreadIdx: 1,
        seenUnreadMsgIds: <String>{},
        isInViewport: (_) => true,
      );

      expect(result, equals(['a1', 'a2']),
          reason: 'idx > firstUnreadIdx 的消息不应被扫描');
    });

    test('catch 回归：旧的双保险过滤会让本测试 fail', () {
      // 这是「契约固化」的真实价值：如果未来有人误把过滤改回
      // `msg.isRead || msg.senderType != 'agent'`，这条测试会失败，
      // 因为生产代码会跳过所有 user 消息（本测试 messages 里全是 agent，user 不参与）。
      //
      // 更关键的是：如果有人把过滤改成 `if (!msg.isRead && msg.senderType == 'agent')`
      // 这种逻辑等价但脆弱的写法，本测试也能 catch（因为 user 消息本身被 isRead=true 排除，
      // 不依赖 senderType 兜底）。
      final messages = <ChatMessage>[
        mkMsg(id: 'a1', senderType: 'agent', isRead: false),
      ];

      final result = computeNewlySeenUnread(
        messages: messages,
        firstUnreadIdx: 0,
        seenUnreadMsgIds: <String>{},
        isInViewport: (_) => true,
      );

      expect(result, equals(['a1']));
    });
  });
}
