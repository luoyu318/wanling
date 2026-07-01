import 'dart:async';
import 'package:app/models/ws_message.dart';
import 'package:app/services/websocket_service.dart';

/// 测试用 WebSocketService 替身：用 StreamController 模拟 messages 流。
///
/// 设计说明：WebSocketService 虽含若干私有字段，但所有方法均有默认实现，
/// 子类只需重写 [messages] getter 即可注入测试消息流。父类构造期间创建的
/// _messageController 不会产生副作用（仅占内存，测试生命周期内可忽略）。
class FakeWS extends WebSocketService {
  final StreamController<WSMessage> _controller =
  StreamController<WSMessage>.broadcast();
  final StreamController<WSMessage> _friendController =
  StreamController<WSMessage>.broadcast();

  @override
  Stream<WSMessage> get messages => _controller.stream;

  @override
  Stream<WSMessage> get friendUpdates => _friendController.stream;

  /// 测试 helper：注入一条 WSMessage 到 messages 流，模拟服务端推送。
  void emit(WSMessage msg) {
    _controller.add(msg);
  }

  /// 测试 helper：注入一条 WSMessage 到 friendUpdates 流，模拟好友事件推送。
  void emitFriend(WSMessage msg) {
    _friendController.add(msg);
  }

  @override
  void disconnect() {
    _controller.close();
    _friendController.close();
  }
}
