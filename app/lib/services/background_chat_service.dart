import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/ws_message.dart';
import 'notification_service.dart';
import '../utils/notification_payload.dart';

/// IPC handler 名称（UI ↔ Service 通信）。
class _Ipc {
  static const setLifecycle = 'setAppLifecycle';
  static const start = 'start';
  static const stop = 'stop';
}

/// service isolate 入口。必须 top-level 函数 + @pragma 注解。
@pragma('vm:entry-point')
void backgroundChatServiceEntry(ServiceInstance service) {
  // 确保 Flutter binding 已初始化（idempotent）。
  // flutter_background_service 5.x 声称自动初始化，但部分 ROM 上不一定。
  WidgetsFlutterBinding.ensureInitialized();

  // runZonedGuarded 兜底，任何未捕获异常不崩 isolate。
  runZonedGuarded(
    () {
      final bgService = BackgroundChatService(service);
      bgService.run();
    },
    (error, stack) {
      debugPrint('[bg-service] isolate crash: $error\n$stack');
    },
  );
}

class BackgroundChatService {
  final ServiceInstance service;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  String? _baseUrl;
  String? _token;
  bool _appInForeground = false;
  bool _connecting = false;
  int? _lastSeq;

  BackgroundChatService(this.service);

  void run() {
    try {
      service.on(_Ipc.setLifecycle).listen((event) {
        final state = (event as Map?)?['state'] as String?;
        _appInForeground = state == 'foreground';
      });

      service.on(_Ipc.start).listen((event) async {
        final e = event as Map?;
        _baseUrl = e?['baseUrl'] as String?;
        _token = e?['token'] as String?;
        if (_baseUrl != null && _token != null) {
          await _safeConnect();
        }
      });

      service.on(_Ipc.stop).listen((event) {
        _disconnectWs();
        _token = null;
      });
    } catch (e) {
      debugPrint('[bg-service] run() IPC 注册失败: $e');
    }

    _autoRestore();
  }

  Future<void> _autoRestore() async {
    try {
      // 延迟 2s 等 Flutter engine 插件通道就绪
      await Future.delayed(const Duration(seconds: 2));

      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('token');
      final baseUrl = prefs.getString('base_url');
      if (token != null && baseUrl != null) {
        _baseUrl = baseUrl;
        _token = token;
        await _safeConnect();
      }
    } catch (e) {
      debugPrint('[bg-service] _autoRestore 失败: $e');
      // 5 秒后重试一次
      await Future.delayed(const Duration(seconds: 5));
      try {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('token');
        final baseUrl = prefs.getString('base_url');
        if (token != null && baseUrl != null) {
          _baseUrl = baseUrl;
          _token = token;
          await _safeConnect();
        }
      } catch (_) {}
    }
  }

  Future<void> _safeConnect() async {
    try {
      await _connectWs();
    } catch (e) {
      debugPrint('[bg-service] _connectWs 失败: $e');
      _scheduleReconnect();
    }
  }

  Future<void> _connectWs() async {
    if (_baseUrl == null || _token == null) return;
    if (_connecting) return;
    _connecting = true;

    // 先 cancel 旧 subscription 再 close sink，避免 onDone 触发 _scheduleReconnect
    // 引入自循环（_autoRestore 与 IPC 'start' 几乎同时触发 _safeConnect 时尤甚）。
    _channelSub?.cancel();
    _channelSub = null;
    if (_channel != null) {
      try {
        await _channel!.sink.close();
      } catch (_) {}
      _channel = null;
    }

    final wsUrl = _baseUrl!.replaceFirst('http', 'ws');
    _channel = WebSocketChannel.connect(Uri.parse('$wsUrl/ws'));
    _channelSub = _channel!.stream.listen(
      (data) => _safeHandleMessage(data),
      onError: (_) {
        _connecting = false;
        _scheduleReconnect();
      },
      onDone: () {
        _connecting = false;
        _scheduleReconnect();
      },
    );
  }

  void _disconnectWs() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _channelSub?.cancel();
    _channelSub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (_token != null) _safeConnect();
    });
  }

  void _safeHandleMessage(String raw) {
    try {
      _handleMessage(raw);
    } catch (e) {
      debugPrint('[bg-service] _handleMessage 异常: $e');
    }
  }

  Future<void> _handleMessage(String raw) async {
    final msg = WSMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);

    if (msg.s != null) _lastSeq = msg.s;

    if (msg.op == OpCodes.hello) {
      _sendIdentify();
      final interval = ((msg.d as Map?)?['heartbeat_interval'] as int?) ?? 30000;
      _startHeartbeat(interval);
      _connecting = false;
      return;
    }

    if (msg.t != 'MESSAGE_CREATE') return;

    final data = msg.d as Map<String, dynamic>?;
    if (data == null) return;

    if (data['sender_type'] != 'agent') return;

    if (_appInForeground) return;

    final convId = data['conversation_id'] as String?;
    final agentId = data['sender_id'] as String?;
    final content = data['content'] as Map<String, dynamic>?;
    if (convId == null || agentId == null || content == null) return;

    final msgType = content['msg_type'] as String? ?? 'text';
    final msgData = content['data'] as Map<String, dynamic>?;
    final body = messagePreview(msgType: msgType, data: msgData);

    try {
      final prefs = await SharedPreferences.getInstance();
      final agentName = prefs.getString('agent_name_$agentId') ?? 'Agent';

      await NotificationService.instance.showMessageNotification(
        payload: NotificationPayload(
          convId: convId,
          agentId: agentId,
          agentName: agentName,
        ),
        body: body,
      );
    } catch (e) {
      debugPrint('[bg-service] 通知发送失败: $e');
    }
  }

  void _sendIdentify() {
    if (_token == null) return;
    _channel?.sink.add(jsonEncode({
      'op': OpCodes.identify,
      'd': {'token': _token},
    }));
    if (_lastSeq != null) {
      _channel?.sink.add(jsonEncode({
        'op': OpCodes.resume,
        'd': {'last_seq': _lastSeq},
      }));
    }
  }

  void _startHeartbeat(int intervalMs) {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) {
        try {
          _channel?.sink.add(jsonEncode({'op': OpCodes.heartbeat}));
        } catch (_) {}
      },
    );
  }
}
