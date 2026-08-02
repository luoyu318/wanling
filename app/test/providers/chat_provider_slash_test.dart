import 'package:app/models/message.dart';
import 'package:app/models/msg_type.dart';
import 'package:app/models/unread_info.dart';
import 'package:app/providers/chat_provider.dart';
import 'package:app/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_ws.dart';

class _MockApi extends Mock implements ApiService {}

void main() {
  late _MockApi api;
  late FakeWS ws;

  setUp(() {
    api = _MockApi();
    ws = FakeWS();
    // _initialize 会调 getUnreadInfo + getMessagesBefore(无未读路径) +
    // getMessages(兜底);getConversation 缺 stub 抛错被 catch 静默吞掉。
    when(() => api.getUnreadInfo(any()))
        .thenAnswer((_) async => const UnreadInfo(unreadCount: 0));
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => <ChatMessage>[]);
    when(() => api.getMessages(any(),
            limit: any(named: 'limit'), offset: any(named: 'offset')))
        .thenAnswer((_) async => <ChatMessage>[]);
  });

  test('sendSlash 发送 _slash content.data 并插入 slash_echo 乐观气泡', () async {
    final notifier = ChatNotifier(api, ws, 'conv-1', 'agent-1', 'user-1');
    // _initialize 在构造函数里 fire-and-forget,等异步尾巴跑完。
    await Future.delayed(const Duration(milliseconds: 50));

    Map<String, dynamic>? captured;
    when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
      captured = inv.positionalArguments[1] as Map<String, dynamic>;
      return (messageId: 'srv-1', createdAt: DateTime.utc(2026, 7, 18));
    });

    await notifier.sendSlash('compact', '保留 env-meta');

    // 验证 sendMessage 收到的 content 带 _slash 字段
    // (msg_type=slash_echo:48e240e 改造后本地乐观与 server 发送共用同一 content,
    //  plugin engine 只看 data._slash 不依赖 msg_type,见 engine.ts:67)
    expect(captured, isNotNull);
    expect(captured!['msg_type'], MsgType.slashEcho.value);
    final data = captured!['data'] as Map<String, dynamic>;
    expect(data['text'], '');
    expect(data['_slash'], {'name': 'compact', 'args': '保留 env-meta'});

    // 验证本地乐观消息用 slash_echo 类型(renderer 识别)
    final msgs = notifier.state.displayMessages;
    expect(msgs, isNotEmpty);
    final first = msgs.first;
    final mt = MsgTypeX.fromString(first.content['msg_type'] as String?);
    expect(mt, MsgType.slashEcho);
    final echoData = first.content['data'] as Map<String, dynamic>;
    // 48e240e 改造后本地乐观与 server 共用同一 content,data 结构含 _slash 嵌套 + display
    final slash = echoData['_slash'] as Map<String, dynamic>;
    expect(slash['name'], 'compact');
    expect(slash['args'], '保留 env-meta');
    // display 含 /name(可读形式),覆盖空参 / 非空参两种 display 模板
    expect(echoData['display'], contains('/compact'));
    expect(echoData['display'], contains('保留 env-meta'));
  });

  test('sendSlash 无参时 args 空字符串,display 不带分隔符后缀', () async {
    final notifier = ChatNotifier(api, ws, 'conv-1', null, 'u');
    await Future.delayed(const Duration(milliseconds: 50));

    Map<String, dynamic>? captured;
    when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
      captured = inv.positionalArguments[1] as Map<String, dynamic>;
      return (messageId: 'srv-2', createdAt: DateTime.utc(2026, 7, 18));
    });

    await notifier.sendSlash('init', '');

    expect(captured, isNotNull);
    final data = captured!['data'] as Map<String, dynamic>;
    expect(data['_slash'], {'name': 'init', 'args': ''});

    // display 模板:无参时不带 ' · ' 后缀
    final echoData =
        notifier.state.displayMessages.first.content['data'] as Map<String, dynamic>;
    expect(echoData['display'], '▶ /init');
  });

  test('sendSlash 失败时乐观消息切 failed 态(对齐 sendText 失败路径)', () async {
    final notifier = ChatNotifier(api, ws, 'conv-1', null, 'u');
    await Future.delayed(const Duration(milliseconds: 50));

    when(() => api.sendMessage(any(), any()))
        .thenThrow(Exception('network down'));

    await notifier.sendSlash('compact', 'x');

    final msgs = notifier.state.displayMessages;
    expect(msgs, isNotEmpty);
    expect(msgs.first.status, MessageStatus.failed);
  });
}
