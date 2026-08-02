import 'package:app/models/message.dart';
import 'package:app/models/unread_info.dart';
import 'package:app/providers/chat_provider.dart';
import 'package:app/providers/chat_state.dart' show ModelOverride;
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
    // _initialize 调 getUnreadInfo + getMessagesBefore(无未读路径),
    // 兜底分支可能调 getMessages,一并 stub。
    when(() => api.getUnreadInfo(any()))
        .thenAnswer((_) async => const UnreadInfo(unreadCount: 0));
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => <ChatMessage>[]);
    when(() => api.getMessages(any(),
            limit: any(named: 'limit'), offset: any(named: 'offset')))
        .thenAnswer((_) async => <ChatMessage>[]);
  });

  group('ChatNotifier.sendSlash _model 透传', () {
    test('modelOverride 非空时 _model 写入 content.data', () async {
      final notifier = ChatNotifier(api, ws, 'conv-1', 'agent-1', 'user-1');
      // _initialize 在构造函数里 fire-and-forget,等异步尾巴跑完。
      await Future.delayed(const Duration(milliseconds: 50));

      // 通过 selectModel 设置 modelOverride(对称生产代码路径)。
      notifier.selectModel(const ModelOverride(
        providerID: 'p1',
        modelID: 'm1',
      ));

      Map<String, dynamic>? captured;
      when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
        captured = inv.positionalArguments[1] as Map<String, dynamic>;
        return (messageId: 'srv-1', createdAt: DateTime.utc(2026, 7, 18));
      });

      await notifier.sendSlash('compact', '保留 env-meta');

      expect(captured, isNotNull);
      final data = captured!['data'] as Map<String, dynamic>;
      // snake_case 键(WS 协议层),provider_id/model_id 来自 ModelOverride。
      expect(data['_model'], {
        'provider_id': 'p1',
        'model_id': 'm1',
      });
      // _slash 透传不变。
      expect(data['_slash'], {'name': 'compact', 'args': '保留 env-meta'});
    });

    test('modelOverride 为 null 时 content.data 不含 _model 键', () async {
      final notifier = ChatNotifier(api, ws, 'conv-1', null, 'u');
      await Future.delayed(const Duration(milliseconds: 50));

      // 默认 modelOverride 即 null,不调 selectModel。

      Map<String, dynamic>? captured;
      when(() => api.sendMessage(any(), any())).thenAnswer((inv) async {
        captured = inv.positionalArguments[1] as Map<String, dynamic>;
        return (messageId: 'srv-2', createdAt: DateTime.utc(2026, 7, 18));
      });

      await notifier.sendSlash('clear', '');

      expect(captured, isNotNull);
      final data = captured!['data'] as Map<String, dynamic>;
      expect(data.containsKey('_model'), isFalse);
      // _slash 仍正常透传。
      expect(data['_slash'], {'name': 'clear', 'args': ''});
    });
  });
}
