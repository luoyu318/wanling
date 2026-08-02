import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/websocket_service.dart';

void main() {
  group('WebSocketService connectionState', () {
    test('初始 currentValue 为 ConnState.disconnected', () {
      final ws = WebSocketService();
      expect(ws.currentConnState, ConnState.disconnected);
    });

    test('ConnState 枚举有 3 个值', () {
      expect(ConnState.values.length, 3);
      expect(ConnState.values, contains(ConnState.disconnected));
      expect(ConnState.values, contains(ConnState.connecting));
      expect(ConnState.values, contains(ConnState.connected));
    });

    test('connectionStateStream 可订阅（不抛异常）', () async {
      final ws = WebSocketService();
      // 仅订阅一下，不应抛
      final sub = ws.connectionStateStream.listen((_) {});
      await Future.delayed(const Duration(milliseconds: 10));
      await sub.cancel();
    });

    test('configure 设置 baseUrl + token 不抛', () {
      final ws = WebSocketService();
      ws.configure(baseUrl: 'ws://localhost:18008', token: 'fake');
      expect(ws.currentConnState, ConnState.disconnected);
    });
  });

  group('WebSocketService controller rebuild (F1)', () {
    test('disconnect 关闭 4 个 broadcast controller', () {
      final ws = WebSocketService();
      expect(ws.isTypingControllerClosed, false);
      expect(ws.isMessageUpdateControllerClosed, false);
      expect(ws.isConversationUpdatesControllerClosed, false);
      expect(ws.isFriendUpdatesControllerClosed, false);
      expect(ws.isStreamControllerClosed, false);

      ws.disconnect();

      expect(ws.isTypingControllerClosed, true);
      expect(ws.isMessageUpdateControllerClosed, true);
      expect(ws.isConversationUpdatesControllerClosed, true);
      expect(ws.isFriendUpdatesControllerClosed, true);
      expect(ws.isStreamControllerClosed, true);
    });

    test('testEnsureControllers 重建已关闭的 controller', () {
      final ws = WebSocketService();
      ws.disconnect();
      expect(ws.isTypingControllerClosed, true);
      expect(ws.isStreamControllerClosed, true);

      ws.testEnsureControllers();

      expect(ws.isTypingControllerClosed, false);
      expect(ws.isMessageUpdateControllerClosed, false);
      expect(ws.isConversationUpdatesControllerClosed, false);
      expect(ws.isFriendUpdatesControllerClosed, false);
      expect(ws.isStreamControllerClosed, false);
    });

    test('testEnsureControllers 对未关闭的 controller 是 no-op（不会重建）', () {
      final ws = WebSocketService();
      // 未 disconnect，controller 都是 open
      ws.testEnsureControllers();
      expect(ws.isTypingControllerClosed, false); // 仍是原实例
    });
  });
}
