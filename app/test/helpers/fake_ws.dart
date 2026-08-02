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
  final StreamController<WSMessage> _messageReadController =
  StreamController<WSMessage>.broadcast();
  final StreamController<WSMessage> _messageUpdateController =
  StreamController<WSMessage>.broadcast();
  final StreamController<WSMessage> _sessionMetaUpdateController =
  StreamController<WSMessage>.broadcast();
  final StreamController<Map<String, dynamic>> _sessionStatusController =
  StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _streamController =
  StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<WSMessage> get messages => _controller.stream;

  @override
  Stream<WSMessage> get friendUpdates => _friendController.stream;

  @override
  Stream<WSMessage> get messageReads => _messageReadController.stream;

  @override
  Stream<WSMessage> get messageUpdates => _messageUpdateController.stream;

  @override
  Stream<WSMessage> get sessionMetaUpdates =>
      _sessionMetaUpdateController.stream;

  @override
  Stream<Map<String, dynamic>> get sessionStatusStream =>
      _sessionStatusController.stream;

  @override
  Stream<Map<String, dynamic>> get streamEvents => _streamController.stream;

  /// 测试 helper：注入一条 WSMessage 到 messages 流，模拟服务端推送。
  void emit(WSMessage msg) {
    _controller.add(msg);
  }

  /// 测试 helper：注入一条 WSMessage 到 friendUpdates 流，模拟好友事件推送。
  void emitFriend(WSMessage msg) {
    _friendController.add(msg);
  }

  /// 测试 helper：注入一条 MESSAGE_READ 到 messageReads 流,模拟多端同步事件。
  void emitMessageRead(WSMessage msg) {
    _messageReadController.add(msg);
  }

  /// 测试 helper：注入一条 MESSAGE_UPDATE 到 messageUpdates 流,
  /// 模拟服务端消息内容变更(task 卡片 PATCH / 已读标记等)。
  void emitUpdate(WSMessage msg) {
    _messageUpdateController.add(msg);
  }

  /// 测试 helper：注入一条 SESSION_META_UPDATE 到 sessionMetaUpdates 流,
  /// 模拟 plugin 写完 session_meta 后 server 广播给 user 端。
  void emitSessionMetaUpdate(WSMessage msg) {
    _sessionMetaUpdateController.add(msg);
  }

  /// 测试 helper：注入一条 SESSION_STATUS 事件。
  void emitSessionStatus(Map<String, dynamic> d) {
    _sessionStatusController.add(d);
  }

  /// 测试 helper：注入一块 op=14 STREAM delta 到 streamEvents 流,
  /// 模拟 plugin 流式输出。delta 不入库,仅推给正在观看的 user 端。
  void emitStream(Map<String, dynamic> d) {
    _streamController.add(d);
  }

  @override
  void disconnect() {
    _controller.close();
    _friendController.close();
    _messageReadController.close();
    _messageUpdateController.close();
    _sessionMetaUpdateController.close();
    _sessionStatusController.close();
    _streamController.close();
  }
}
