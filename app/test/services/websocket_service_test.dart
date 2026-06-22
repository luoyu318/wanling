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
}
