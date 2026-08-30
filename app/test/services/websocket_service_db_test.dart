import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_local_message_store.dart';

void main() {
  late WebSocketService ws;
  late FakeLocalMessageStore store;

  setUp(() {
    store = FakeLocalMessageStore();
    ws = WebSocketService(store: store);
    ws.configure(baseUrl: 'http://test', token: 'token');
  });

  test('MESSAGE_CREATE 写 DB', () async {
    final dispatch = _dispatchMessage('MESSAGE_CREATE', {
      'id': 'msg1',
      'conversation_id': 'conv1',
      'sender_type': 'user',
      'sender_id': 'uid',
      'sender_name': 'Alice',
      'sender_avatar_url': '',
      'content': {'msg_type': 'text', 'data': {'text': 'hi'}},
      'created_at': '2026-07-05T10:00:00Z',
    }, seq: 100);
    await ws.testHandleDispatch(dispatch);
    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(msgs.length, 1);
    expect(msgs.first.id, 'msg1');
  });

  test('MESSAGE_DELETE scope=hide 调 deleteMessage', () async {
    await store.putMessage(_mkMsg('msg1'));
    final dispatch = _dispatchMessage('MESSAGE_DELETE', {
      'conversation_id': 'conv1',
      'ids': ['msg1'],
      'scope': 'hide',
    });
    await ws.testHandleDispatch(dispatch);
    expect(await store.getMessages(conversationId: 'conv1'), isEmpty);
  });

  test('MESSAGE_DELETE scope=recall 调 markRecalled', () async {
    await store.putMessage(_mkMsg('msg1'));
    final dispatch = _dispatchMessage('MESSAGE_DELETE', {
      'conversation_id': 'conv1',
      'ids': ['msg1'],
      'scope': 'recall',
      'sender_name': 'Alice',
    });
    await ws.testHandleDispatch(dispatch);
    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(msgs.first.isRecalled, true);
    expect(msgs.first.recalledByName, 'Alice');
  });

  test('MESSAGE_UPDATE 调 updateContent', () async {
    await store.putMessage(_mkMsg('msg1'));
    final dispatch = _dispatchMessage('MESSAGE_UPDATE', {
      'conversation_id': 'conv1',
      'message_id': 'msg1',
      'content': {'msg_type': 'text', 'data': {'text': 'edited'}},
    });
    await ws.testHandleDispatch(dispatch);
    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(((msgs.first.content['data'] as Map)['text']) as String, 'edited');
  });

  test('seq 字段调 setGlobalLastSeq', () async {
    final dispatch = _dispatchMessage('MESSAGE_CREATE', {
      'id': 'msg1',
      'conversation_id': 'conv1',
      'sender_type': 'user',
      'sender_id': 'uid',
      'content': {'msg_type': 'text', 'data': {'text': 'hi'}},
      'created_at': '2026-07-05T10:00:00Z',
    }, seq: 42);
    await ws.testHandleDispatch(dispatch);
    expect(await store.getGlobalLastSeq(), 42);
  });

  test('MESSAGE_UPDATE message_id 为 null 时 silently skip', () async {
    await store.putMessage(_mkMsg('msg1'));
    final dispatch = _dispatchMessage('MESSAGE_UPDATE', {
      'conversation_id': 'conv1',
      'message_id': null,
      'content': {'msg_type': 'text', 'data': {'text': 'edited'}},
    });
    await ws.testHandleDispatch(dispatch);
    // content 没改
    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(((msgs.first.content['data'] as Map)['text']) as String, 'hi');
  });

  test('MESSAGE_UPDATE content 为 null 时 silently skip', () async {
    await store.putMessage(_mkMsg('msg1'));
    final dispatch = _dispatchMessage('MESSAGE_UPDATE', {
      'conversation_id': 'conv1',
      'message_id': 'msg1',
      'content': null,
    });
    await ws.testHandleDispatch(dispatch);
    final msgs = await store.getMessages(conversationId: 'conv1');
    expect(((msgs.first.content['data'] as Map)['text']) as String, 'hi');
  });
}

Map<String, dynamic> _dispatchMessage(
    String t, Map<String, dynamic> d,
    {int? seq}) {
  return {'op': 0, 't': t, 'd': d, 's': ?seq};
}

ChatMessage _mkMsg(String id) => ChatMessage(
      id: id,
      conversationId: 'conv1',
      senderType: 'user',
      senderId: 'uid',
      content: {'msg_type': 'text', 'data': {'text': 'hi'}},
      isRead: true,
      createdAt: DateTime(2026, 7, 5),
      status: MessageStatus.sent,
    );
