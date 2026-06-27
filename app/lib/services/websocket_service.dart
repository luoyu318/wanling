import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/ws_message.dart';

/// WebSocket 连接状态。banner 用 disconnected 显示「连接断开」。
enum ConnState {
  disconnected,
  connecting,
  connected,
}

class WebSocketService {
  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  String? _token;
  String? _baseUrl;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  int? _lastSeq;
  // 防止重连风暴：connect 已经在排队/进行时，跳过新的 _reconnect 调用。
  bool _connecting = false;
  // disconnect 后不再重连。configure/connect 时清。
  bool _stopped = false;

  final _messageController = StreamController<WSMessage>.broadcast();
  Stream<WSMessage> get messages => _messageController.stream;

  /// TYPING_START 事件流。元素是 dispatch 的 d 字段（{user_id, agent_id}）。
  /// ChatPage 经 typingProvider 订阅，按 agent_id 跟踪 typing 状态。
  /// 设计：单列流而非复用 messages 流，避免 chatProvider 误把 TYPING_START
  /// 当 MESSAGE_CREATE 处理（messages 流只暴露给订阅 MESSAGE_CREATE 的消费者）。
  final _typingController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get typingStream => _typingController.stream;

  /// MESSAGE_UPDATE 事件流（审批状态变更推送等）。
  /// 单列流，避免 chatProvider 把 UPDATE 当 CREATE 重复插入消息列表。
  /// chatProvider 监听本流后按 d.id 定位已有消息做局部更新（如 approval 状态切换）。
  final _messageUpdateController = StreamController<WSMessage>.broadcast();
  Stream<WSMessage> get messageUpdates => _messageUpdateController.stream;

  // 连接状态：private setter，对外只读 currentValue + 流。
  final _connStateController = StreamController<ConnState>.broadcast();
  Stream<ConnState> get connectionStateStream => _connStateController.stream;
  ConnState _currentConnState = ConnState.disconnected;
  ConnState get currentConnState => _currentConnState;

  void _setConnState(ConnState s) {
    if (_currentConnState == s) return;
    _currentConnState = s;
    _connStateController.add(s);
  }

  void configure({required String baseUrl, required String token}) {
    _baseUrl = baseUrl;
    _token = token;
    _stopped = false;
  }

  Future<void> connect() async {
    if (_baseUrl == null || _token == null) return;
    if (_connecting) return; // 防止并发 connect
    _connecting = true;
    _stopped = false;
    _setConnState(ConnState.connecting);

    // 先清掉旧 channel + subscription，避免新旧同时存在触发多次 onDone
    await _cleanupChannel();

    final wsUrl = _baseUrl!.replaceFirst('http', 'ws');
    _channel = WebSocketChannel.connect(Uri.parse('$wsUrl/ws'));

    _channelSub = _channel!.stream.listen(
      (data) {
        final msg = WSMessage.fromJson(jsonDecode(data));
        _handleMessage(msg);
      },
      onError: (error) {
        debugPrint('[ws] onError: $error');
        _setConnState(ConnState.disconnected);
        _connecting = false;
        _reconnect();
      },
      onDone: () {
        debugPrint('[ws] onDone(连接关闭) closeCode=${_channel?.closeCode}');
        _setConnState(ConnState.disconnected);
        _connecting = false;
        _reconnect();
      },
    );
    // 连接尝试完成（hello 不到达不算 connected；hello 来了在 _handleMessage 里
    // 把 _connecting 置 false）。这里兜底：网络层连接建立后短时间内若 hello 到
    // 不了，_connecting 仍可能卡住，但下次 connect() 入口检查会拦。
    // 不在此处把 _connecting=false，等 hello 真正到达再清。
  }

  Future<void> _cleanupChannel() async {
    _channelSub?.cancel();
    _channelSub = null;
    if (_channel != null) {
      try {
        await _channel!.sink.close();
      } catch (_) {}
      _channel = null;
    }
  }

  void _handleMessage(WSMessage msg) {
    switch (msg.op) {
      case OpCodes.hello:
        // 总是先 Identify：server ws_handler 要求首条消息必须是 Identify，
        // 否则直接关闭连接。即使 _lastSeq 有值（断线重连），也先 Identify
        // 让 server 注册 client，再补 Resume 拉取 missed messages。
        // server 重启后 buffer 为空，Resume 不会补到任何消息，无害。
        _connecting = false; // hello 到达，连接真正建立
        send(WSMessage(op: OpCodes.identify, d: {'token': _token}));
        if (_lastSeq != null) {
          send(WSMessage(op: OpCodes.resume, d: {'last_seq': _lastSeq}));
        }
        final interval = (msg.d as Map)['heartbeat_interval'] as int;
        _startHeartbeat(interval);
        _setConnState(ConnState.connected);
        break;
      case OpCodes.heartbeatAck:
        break;
      case OpCodes.reconnect:
        _setConnState(ConnState.disconnected);
        _connecting = false;
        _reconnect();
        break;
      case OpCodes.dispatch:
        // TYPING_START 分流：单独暴露给 typingProvider，
        // 不进 messages 流（messages 流给 chatProvider 处理 MESSAGE_CREATE）。
        if (msg.t == 'TYPING_START') {
          final d = msg.d as Map<String, dynamic>?;
          if (d != null) {
            _typingController.add(d);
          }
          return;
        }
        // MESSAGE_UPDATE 分流：审批状态变更等走单独流，避免被 chatProvider
        // 当 MESSAGE_CREATE 重复插入。seq 同步逻辑共用。
        if (msg.t == 'MESSAGE_UPDATE') {
          if (msg.s != null) _lastSeq = msg.s;
          _messageUpdateController.add(msg);
          return;
        }
        if (msg.s != null) _lastSeq = msg.s;
        _messageController.add(msg);
        break;
    }
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      // 纯心跳：只表达「我还活着」。seq 同步与断线补发由 Resume 通道
      // （116-118 行）负责，server 心跳分支不读 d，带上只会误导维护者。
      // 对齐 background_chat_service 的干净写法。
      (_) => send(WSMessage(op: OpCodes.heartbeat)),
    );
  }

  void send(WSMessage msg) {
    _channel?.sink.add(jsonEncode(msg.toJson()));
  }

  void sendMessage(String agentId, Map<String, dynamic> content) {
    send(WSMessage(
      op: OpCodes.dispatch,
      t: 'MESSAGE_CREATE',
      d: {'agent_id': agentId, 'content': content},
    ));
  }

  /// 上报当前正在看的会话（op=3）。服务端据此决定 agent 发消息时是否计未读。
  /// convId 传 null 或空 = 退出会话（没在看任何会话）。
  /// ChatPage initState 调 setActiveConv(convId)，dispose 调 setActiveConv(null)。
  void setActiveConv(String? convId) {
    send(WSMessage(op: OpCodes.setActiveConv, d: {'conv_id': convId ?? ''}));
  }

  void _reconnect() {
    if (_stopped) return; // disconnect 后不再重连
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_token != null && !_stopped) connect();
    });
  }

  void disconnect() {
    _stopped = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _channelSub?.cancel();
    _channelSub = null;
    _channel?.sink.close();
    _channel = null;
    _token = null;
    _connecting = false;
    _setConnState(ConnState.disconnected);
    _typingController.close();
    _messageUpdateController.close();
  }
}
