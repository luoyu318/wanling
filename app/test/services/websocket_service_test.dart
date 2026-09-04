import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/services/websocket_service.dart';

/// 录制型 WS 替身:拦截 send 捕获全部出站帧(不发真实网络)。
class _RecordingWS extends WebSocketService {
  final List<WSMessage> sent = [];

  @override
  void send(WSMessage msg) => sent.add(msg);
}

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

  group('mp 云数据订阅重连重放', () {
    test('hello 到达（重连成功）后重放 mpSubscribe 帧，且在 Identify 之后', () async {
      final ws = _RecordingWS();
      ws.configure(baseUrl: 'ws://localhost:18008', token: 'tok');
      // 页面打开时的原始订阅
      ws.sendMpSubscribe('demo-app', ['records', 'notes']);

      // 模拟断线重连:新连接 hello 到达(_handleMessage hello 分支)
      await ws.testHandleDispatch({
        'op': OpCodes.hello,
        'd': {'heartbeat_interval': 60000},
      });

      final subs = ws.sent.where((m) => m.op == OpCodes.mpSubscribe).toList();
      // 第一条为原始订阅帧,第二条为重连重放帧
      expect(subs.length, 2);
      final replay = subs.last;
      expect((replay.d as Map)['appid'], 'demo-app');
      expect(((replay.d as Map)['colls'] as List).toList(), ['records', 'notes']);
      // server ws_handler 要求首条消息必须是 Identify,重放须在其后
      final identifyIdx = ws.sent.indexWhere((m) => m.op == OpCodes.identify);
      final replayIdx = ws.sent.indexOf(replay);
      expect(identifyIdx, greaterThanOrEqualTo(0));
      expect(replayIdx, greaterThan(identifyIdx));

      ws.disconnect(); // 清 heartbeat Timer
    });

    test('unsubscribe 后重连不重放', () async {
      final ws = _RecordingWS();
      ws.configure(baseUrl: 'ws://localhost:18008', token: 'tok');
      ws.sendMpSubscribe('demo-app', ['records']);
      ws.sendMpUnsubscribe();

      await ws.testHandleDispatch({
        'op': OpCodes.hello,
        'd': {'heartbeat_interval': 60000},
      });

      final subs = ws.sent.where((m) => m.op == OpCodes.mpSubscribe).toList();
      expect(subs.length, 1); // 仅原始订阅帧,无重放
      ws.disconnect();
    });

    test('从未订阅过时 hello 不发 mpSubscribe', () async {
      final ws = _RecordingWS();
      ws.configure(baseUrl: 'ws://localhost:18008', token: 'tok');
      await ws.testHandleDispatch({
        'op': OpCodes.hello,
        'd': {'heartbeat_interval': 60000},
      });
      expect(ws.sent.any((m) => m.op == OpCodes.mpSubscribe), false);
      ws.disconnect();
    });
  });
}
