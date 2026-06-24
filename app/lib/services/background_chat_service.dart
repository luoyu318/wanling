import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/ws_message.dart';
import '../utils/avatar_bitmap.dart';
import 'notification_service.dart';
import '../utils/notification_payload.dart';

/// IPC handler 名称（UI ↔ Service 通信）。
class _Ipc {
  static const setLifecycle = 'setAppLifecycle';
  static const setActiveConv = 'setActiveConv';
  static const syncAgentAvatar = 'syncAgentAvatar'; // UI 同步 agent avatar_url(供通知下载头像)
  static const start = 'start';
  static const stop = 'stop';
}

/// 未读计数器(bg-service isolate 本地维护)。
///
/// 进入会话(setActiveConv)清零,收 agent 消息累加。
/// 用于通知 body 的 `[N条]` 前缀。纯类便于单测。
class UnreadCounter {
  final Map<String, int> _counts = {};

  int get(String convId) => _counts[convId] ?? 0;

  void increment(String convId) {
    _counts[convId] = (_counts[convId] ?? 0) + 1;
  }

  void clear(String convId) {
    _counts[convId] = 0;
  }
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
  /// 当前正在看的会话（由 UI 经 IPC setActiveConv 同步）。空 = 没在任何会话页。
  /// 用于决定本地通知要不要弹：前台且正在看该会话时不弹（用户已直接看到）。
  String? _activeConvId;
  /// 各会话未读计数(用于通知 [N条] 前缀)。进入会话清零,收 agent 消息累加。
  final UnreadCounter _unread = UnreadCounter();
  /// UI 同步过来的 agent avatar_url(agentId → url)。供通知下载头像用。
  final Map<String, String> _avatarUrls = {};
  /// 下载后的头像 bitmap 内存缓存(agentId → PNG bytes)。避免每条消息都查文件缓存。
  final Map<String, Uint8List> _avatarBitmapCache = {};

  BackgroundChatService(this.service);

  void run() {
    try {
      service.on(_Ipc.setLifecycle).listen((event) {
        final state = (event as Map?)?['state'] as String?;
        _appInForeground = state == 'foreground';
      });

      // UI 上报当前活跃会话：ChatPage 进入时 setActiveConv(convId)，离开时 setActiveConv(null)。
      // 用于本地通知过滤——前台且正在看该会话时不弹通知（用户已直接看到）。
      // 进入会话时顺手清零该会话的通知未读计数（复用现有通道,不新增 IPC）。
      service.on(_Ipc.setActiveConv).listen((event) {
        final convId = (event as Map?)?['conv_id'] as String?;
        _activeConvId = (convId == null || convId.isEmpty) ? null : convId;
        if (_activeConvId != null) {
          _unread.clear(_activeConvId!);
        }
      });

      // UI 同步 agent 头像 URL（拉列表后调,供通知下载头像）。
      service.on(_Ipc.syncAgentAvatar).listen((event) {
        final agentId = (event as Map?)?['agentId'] as String?;
        final avatarUrl = (event as Map?)?['avatarUrl'] as String?;
        if (agentId != null) {
          final oldUrl = _avatarUrls[agentId];
          _avatarUrls[agentId] = avatarUrl ?? '';
          // URL 变了 → 清内存 + 文件缓存(防旧头像永久驻留),下次通知重新下载
          if (oldUrl != (avatarUrl ?? '')) {
            _avatarBitmapCache.remove(agentId);
            clearAvatarFileCache(agentId);
          }
        }
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

    // convId 先取出来，下面的「正在看该会话」判断要用。
    final convId = data['conversation_id'] as String?;

    // 通知过滤：用户正在看该会话则不弹也不计数（语义正确:看了不算未读）。
    // 用户直接看到 = APP 在前台 且 正在该会话页（_activeConvId == convId）。
    // 其他情况（前台但不在该会话 / 在别的页面 / APP 在后台）都弹通知。
    final isViewing = _appInForeground && convId == _activeConvId;
    if (isViewing) return;

    final agentId = data['sender_id'] as String?;
    final content = data['content'] as Map<String, dynamic>?;
    if (convId == null || agentId == null || content == null) return;

    // 计数(在通知前累加,N 反映含本条)
    _unread.increment(convId);

    final msgType = content['msg_type'] as String? ?? 'text';
    final msgData = content['data'] as Map<String, dynamic>?;
    final body = messagePreview(msgType: msgType, data: msgData);

    try {
      final prefs = await SharedPreferences.getInstance();
      final agentName = prefs.getString('agent_name_$agentId') ?? 'Agent';

      // 加载头像 bitmap(内存缓存 → 文件缓存 → 下载 → 兜底色块)
      Uint8List? avatarBytes;
      final avatarUrl = _avatarUrls[agentId];
      if (_baseUrl != null && _token != null) {
        // loadAvatarBitmap 必返回非空(下载失败兜底色块),故用空合并直接赋值
        avatarBytes = _avatarBitmapCache[agentId] ??
            await loadAvatarBitmap(
              agentId: agentId,
              name: agentName,
              avatarUrl: avatarUrl,
              baseUrl: _baseUrl!,
              httpHeaders: {'Authorization': 'Bearer $_token'},
            );
        _avatarBitmapCache[agentId] = avatarBytes;
      }

      await NotificationService.instance.showMessageNotification(
        payload: NotificationPayload(
          convId: convId,
          agentId: agentId,
          agentName: agentName,
        ),
        body: body,
        unreadCount: _unread.get(convId),
        avatarBytes: avatarBytes,
        agentName: agentName,
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
