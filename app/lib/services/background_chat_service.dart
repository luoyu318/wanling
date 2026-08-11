import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/ws_message.dart';
import '../utils/avatar_bitmap.dart';
import '../utils/debug_log.dart';
import 'notification_service.dart';
import '../utils/notification_payload.dart';
import '../utils/reconnect_backoff.dart';

/// 通知发送回调。默认走 [NotificationService.instance]，测试可注入替身断言触发。
typedef ShowMessageNotifier = Future<void> Function({
  required NotificationPayload payload,
  required String title,
  required String body,
  required int unreadCount,
  Uint8List? avatarBytes,
});

/// IPC handler 名称（UI ↔ Service 通信）。
class _Ipc {
  static const setLifecycle = 'setAppLifecycle';
  static const setActiveConv = 'setActiveConv';
  static const syncAgentAvatar = 'syncAgentAvatar'; // UI 同步 agent avatar_url(供通知下载头像)
  static const setMyUserId = 'setMyUserId'; // UI 同步当前账号 user_id(防 SharedPreferences 跨 isolate cache 陈旧)
  static const start = 'start';
  static const stop = 'stop';
  static const requestTokenRefresh = 'requestTokenRefresh'; // bg-service 请求主 isolate 刷新 token
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
      debugLog('[bg-service] isolate crash: $error\n$stack');
    },
  );
}

class BackgroundChatService {
  final ServiceInstance service;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Timer? _heartbeat;
  Timer? _reconnectTimer;
  final ReconnectBackoff _backoff = ReconnectBackoff();
  // 防 onError + onDone 双触发吃两次 attempt（与 WebSocketService 同修法）
  bool _reconnectScheduled = false;
  String? _baseUrl;
  String? _token;
  // 默认 true:bg-service 由 APP 启动(autoStart=true),APP 启动时通常在前台。
  // 之前默认 false(保守)导致 APP 启动后第一条消息会误判为后台弹通知——
  // 用户进入会话期间,即使 _activeConvId 正确同步,_appInForeground 仍是 false
  // 直到 lifecycle observer 触发首次前后台切换,弹通知逻辑误判 isViewing=false。
  // 真值由 AppLifecycleObserver.attach() 启动后立即 invoke 一次同步兜底。
  bool _appInForeground = true;
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
  /// 当前账号 user_id(UI IPC 同步)。
  ///
  /// 为什么不直接用 prefs.user_id:SharedPreferences 各 isolate 内有独立 cache,
  /// 主 isolate login 写入后不会自动同步到 bg-service isolate 的 cache,
  /// 导致切换账号 / 多端 echo 场景下 bg-service 用 stale user_id 判断
  /// 「自己发的消息」误判 → 弹自己 echo 的通知。
  ///
  /// IPC 同步是单向 push,主 isolate login/restoreSession/logout 完成后立即 invoke。
  /// 冷启动场景:bg-service 自己 autoRestore 时 prefs 已是最新值(主 isolate 上次
  /// login 写完落盘),fallback 读 prefs 兜底。
  String? _myUserId;

  /// 会话 → 最近一条非本人消息的 sender_id(供聚合卡 MESSAGE_UPDATE 翻转时取 agent 名/头像)。
  ///
  /// 聚合卡创建时 silent=true(bg-service 跳过通知/未读),回合结束 PATCH 翻转
  /// silent=false 的 MESSAGE_UPDATE 广播**不带 sender 字段**(server dispatch.go
  /// BroadcastMessageUpdate 只有 message_id / conversation_id / content),弹通知
  /// 需要 sender 名/头像,故在 MESSAGE_CREATE 阶段记录会话发送者回查。
  /// 取不到(如 bg-service 回合中途才启动)fallback 'Agent' 名 + 无头像,不阻塞通知。
  final Map<String, String> _convSenders = {};

  /// 通知发送出口(MESSAGE_CREATE 与聚合卡翻转共用)。
  final ShowMessageNotifier _showNotification;

  BackgroundChatService(
    this.service, {
    ShowMessageNotifier? showNotification,
  }) : _showNotification =
           showNotification ?? NotificationService.instance.showMessageNotification;

  void run() {
    try {
      service.on(_Ipc.setLifecycle).listen((event) {
        final state = (event as Map?)?['state'] as String?;
        _appInForeground = state == 'foreground';
      });

      // UI 上报当前活跃会话：ChatPage 进入时 setActiveConv(convId)，离开时 setActiveConv(null)。
      // 用于本地通知过滤——前台且正在看该会话时不弹通知（用户已直接看到）。
      // 进入会话时:清零未读计数 + 取消该会话的通知横幅(用户已读到,横幅该消失)。
      // 通知 id 与 notification_service 一致 = convId.hashCode。
      service.on(_Ipc.setActiveConv).listen((event) {
        final convId = (event as Map?)?['conv_id'] as String?;
        _activeConvId = (convId == null || convId.isEmpty) ? null : convId;
        if (_activeConvId != null) {
          _unread.clear(_activeConvId!);
          // 取消该会话的通知横幅(不点通知、直接进 APP 读消息时横幅也消失)
          NotificationService.instance.cancel(_activeConvId!.hashCode);
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

      // UI 同步当前账号 user_id(防 SharedPreferences 跨 isolate cache 陈旧)。
      // 收到空字符串视为 logout,_myUserId 置 null(不让旧账号残留继续匹配 echo)。
      service.on(_Ipc.setMyUserId).listen((event) {
        final uid = (event as Map?)?['user_id'] as String?;
        _myUserId = (uid == null || uid.isEmpty) ? null : uid;
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
      debugLog('[bg-service] run() IPC 注册失败: $e');
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
      debugLog('[bg-service] _autoRestore 失败: $e');
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
      debugLog('[bg-service] _connectWs 失败: $e');
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
        _reconnectFailures++;
        _scheduleReconnect();
      },
      onDone: () {
        _connecting = false;
        _reconnectFailures++;
        _scheduleReconnect();
      },
    );
  }

  void _disconnectWs() {
    _heartbeat?.cancel();
    _heartbeat = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectScheduled = false;
    _backoff.reset();
    _channelSub?.cancel();
    _channelSub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
  }

  /// 连续重连失败计数。超过阈值后通过 IPC 请求主 isolate 刷新 token。
  /// bg-service 是独立 isolate,不能直接调 ApiService。
  /// 主 isolate refresh 成功后会通过 'start' IPC 传新 token,
  /// bg-service 收到后更新 _token,下次重连用新 token。
  int _reconnectFailures = 0;
  static const _tokenRefreshThreshold = 3;

  void _scheduleReconnect() {
    if (_reconnectScheduled) return; // 防 onError+onDone 双触发吃两次 attempt
    _reconnectScheduled = true;
    _reconnectTimer?.cancel();
    final delay = _backoff.next();
    debugLog('[bg-service] 重连等待 ${delay.inMilliseconds}ms');
    _reconnectTimer = Timer(delay, () {
      _reconnectScheduled = false;
      if (_token == null) return;
      // 连续失败超过阈值 → token 可能过期,请求主 isolate 刷新。
      // 主 isolate refresh 成功后通过 'start' IPC 传新 token,
      // bg-service 收到后 _token 更新,下次重连用新 token。
      if (_reconnectFailures >= _tokenRefreshThreshold) {
        debugLog('[bg-service] 连续 $_reconnectFailures 次重连失败,请求主 isolate 刷新 token');
        try {
          service.invoke(_Ipc.requestTokenRefresh);
        } catch (e) {
          debugLog('[bg-service] requestTokenRefresh IPC 失败: $e');
        }
        _reconnectFailures = 0; // 重置,避免每次重连都发 IPC
      }
      _safeConnect();
    });
  }

  void _safeHandleMessage(String raw) {
    try {
      _handleMessage(raw);
    } catch (e) {
      debugLog('[bg-service] _handleMessage 异常: $e');
    }
  }

  Future<void> _handleMessage(String raw) async {
    final msg = WSMessage.fromJson(jsonDecode(raw) as Map<String, dynamic>);

    if (msg.s != null) _lastSeq = msg.s;

    if (msg.op == OpCodes.hello) {
      _sendIdentify();
      _backoff.reset(); // 连接成功，重置退避
      _reconnectFailures = 0; // 连接成功，重置失败计数
      final interval = ((msg.d as Map?)?['heartbeat_interval'] as int?) ?? 30000;
      _startHeartbeat(interval);
      _connecting = false;
      return;
    }

    if (msg.t == 'MESSAGE_UPDATE') {
      await _handleMessageUpdate(msg);
      return;
    }

    if (msg.t != 'MESSAGE_CREATE') return;

    final data = msg.d as Map<String, dynamic>?;
    if (data == null) return;

    final senderType = data['sender_type'] as String?;
    final senderId = data['sender_id'] as String?;

    // participants 模型下 sender 可能是 user 也可能是 agent,
    // 只要不是自己发的就弹通知(覆盖 user-user / agent→user / 群聊场景)。
    // 自己发的 MESSAGE_CREATE echo(S2.1 后 server 不过滤 sender)直接跳过。
    //
    // _myUserId 优先用 IPC 同步过来的内存值(实时)。如果 IPC 还没收到(冷启动 /
    // bg-service 自动 restore 场景),fallback 读 prefs 兜底(主 isolate 上次 login
    // 写入的持久化值)。
    final myUserId = _myUserId ?? (await SharedPreferences.getInstance()).getString('user_id');
    // 诊断 debugLog(kDebugMode 守卫,release 编译期移除,不泄漏):
    // 排查"自己发的消息也弹通知"偶发 bug,需要观察 senderId / myUserId 是否真匹配。
    // [bg-debug] 前缀方便 grep + 后续清理。
    debugLog('[bg-debug] MESSAGE_CREATE senderType=$senderType '
        'senderId=$senderId myUserId=$myUserId '
        '(source=${_myUserId != null ? "IPC" : "prefs"})');
    final isOwn = senderId == myUserId;
    debugLog('[bg-debug] isOwn=$isOwn (senderId==myUserId) → '
        '${isOwn ? "SKIP notif (self echo)" : "continue check isViewing"}');
    if (senderId == null || senderId == myUserId) return;

    // convId 先取出来，下面的「正在看该会话」判断要用。
    final convId = data['conversation_id'] as String?;

    // 通知过滤：用户正在看该会话则不弹也不计数（语义正确:看了不算未读）。
    // 用户直接看到 = APP 在前台 且 正在该会话页（_activeConvId == convId）。
    // 其他情况（前台但不在该会话 / 在别的页面 / APP 在后台）都弹通知。
    final isViewing = _appInForeground && convId == _activeConvId;
    debugLog('[bg-debug] isViewing=$isViewing '
        '(appInFg=$_appInForeground convId=$convId '
        'activeConvId=$_activeConvId) → '
        '${isViewing ? "SKIP notif (user viewing)" : "WILL SHOW notif"}');
    if (isViewing) return;

    final content = data['content'] as Map<String, dynamic>?;
    if (convId == null || content == null) return;

    // 记录会话最近的非本人发送者:聚合卡创建时 silent=true 不弹通知/不计未读,
    // 回合结束 PATCH 翻转 silent=false 的 MESSAGE_UPDATE 广播不带 sender 字段,
    // 需回查本缓存拿 agent 名/头像(取不到 fallback 'Agent')。
    // 此处 senderId 已在上方非空校验(senderId==null 早退)。
    _convSenders[convId] = senderId;

    // silent 消息不打扰用户（过程类信息：AI 思考、工具调用等）
    // 仍通过 WS 到达主 UI 渲染，但 bg-service 跳过通知和未读计数。
    if (content['silent'] == true) return;

    // 计数(在通知前累加,N 反映含本条)
    _unread.increment(convId);

    // 显示名:agent 走 prefs 缓存(agent_name_$agentId),user 走 dispatch payload
    // 的 sender_name(S4.3 加),都拿不到时 fallback「新消息」。
    // prefs 复用上面 myUserId fallback 路径的实例(若 _myUserId 已 IPC 同步则此路径才新建)。
    final senderName = (data['sender_name'] as String?) ??
        (senderType == 'agent'
            ? ((await SharedPreferences.getInstance()).getString('agent_name_$senderId') ?? 'Agent')
            : '新消息');

    await _notifyIncomingMessage(
      convId: convId,
      senderId: senderId,
      senderName: senderName,
      content: content,
      senderAvatarUrl: data['sender_avatar_url'] as String?,
      conversationType: data['conversation_type'] as String?,
      conversationTitle: data['conversation_title'] as String?,
    );
  }

  /// 聚合卡回合结束翻转识别(纯函数,便于单测)。
  ///
  /// MESSAGE_UPDATE 广播的 content 满足「聚合卡回合结束翻转」语义时返回 true,
  /// 应触发通知/未读。两种形态:
  ///   - 全量替换 PATCH(旧协议):`msg_type==aggregate_card && silent==false`
  ///   - 增量 set_silent op(新协议):`data.op=="set_silent" && data.silent==false`
  ///     (增量下 silent 在 data 内而非 content 顶层,见 ai-handbook/websocket-protocol)
  /// generating 阶段(silent 仍 true)或非聚合卡更新 → false,不打扰。
  @visibleForTesting
  static bool isAggregateCardSilentFlip(Map<String, dynamic>? content) {
    if (content == null) return false;
    if (content['msg_type'] != 'aggregate_card') return false;
    final data = content['data'];
    if (data is Map && data['op'] == 'set_silent') {
      return data['silent'] == false;
    }
    return content['silent'] == false;
  }

  /// 聚合卡回合结束 silent 翻转 → 弹通知 + 计未读。
  ///
  /// 聚合卡一次问答 = 一条 silent=true 创建的消息,回合结束 plugin PATCH 成
  /// silent=false + state=done,server 广播 MESSAGE_UPDATE(仅
  /// message_id / conversation_id / content,不带 sender 字段)。此时才对该会话
  /// 弹通知 + unread 计数(与 MESSAGE_CREATE silent=false 口径一致)。
  /// generating 阶段(silent 仍 true)的 MESSAGE_UPDATE 只刷新渲染,直接忽略。
  Future<void> _handleMessageUpdate(WSMessage msg) async {
    final data = msg.d as Map<String, dynamic>?;
    if (data == null) return;
    final convId = data['conversation_id'] as String?;
    final content = data['content'] as Map<String, dynamic>?;
    if (convId == null || content == null || !isAggregateCardSilentFlip(content)) {
      return;
    }

    // 与 MESSAGE_CREATE 同口径:正在看该会话则不弹不计(用户已直接看到)。
    if (_appInForeground && convId == _activeConvId) return;

    // 计数(在通知前累加,N 反映含本条)
    _unread.increment(convId);

    // MESSAGE_UPDATE 广播不带 sender 字段,回查 MESSAGE_CREATE 阶段记录的
    // 会话发送者;取不到(回合中途 bg-service 才启动)fallback 'Agent'。
    final senderId = _convSenders[convId];
    final senderName = senderId != null
        ? ((await SharedPreferences.getInstance())
                    .getString('agent_name_$senderId') ??
                'Agent')
        : 'Agent';

    await _notifyIncomingMessage(
      convId: convId,
      // agentId 字段是占位(点击路由用 convId),无 sender 记录时用 convId 兜底。
      senderId: senderId ?? convId,
      senderName: senderName,
      content: content,
      // 翻转广播 server 附带会话 type/title(对齐 MESSAGE_CREATE payload):
      // agent_session 通知 title=会话标题,群聊 title=群名;老 server 无此字段
      // 时走原单聊 fallback(title=senderName)。
      conversationType: data['conversation_type'] as String?,
      conversationTitle: data['conversation_title'] as String?,
    );
  }

  /// 发送一条「新消息」通知(MESSAGE_CREATE 与聚合卡 MESSAGE_UPDATE 翻转共用)。
  ///
  /// 会话元信息三档通知格式:
  ///   - agent_session:title=会话标题,body=内容(不加 sender 前缀,单 agent 语义)
  ///   - 群聊(group_user/group_mixed):title=群名,body=「${sender}：${内容}」
  ///   - 单聊(dm_*):title=sender 名,body=内容
  /// [senderAvatarUrl] MESSAGE_CREATE 的 dispatch payload 带 sender_avatar_url,
  /// 聚合卡 MESSAGE_UPDATE 不带,fallback 到 _avatarUrls(UI 同步缓存)。
  Future<void> _notifyIncomingMessage({
    required String convId,
    required String senderId,
    required String senderName,
    required Map<String, dynamic> content,
    String? senderAvatarUrl,
    String? conversationType,
    String? conversationTitle,
  }) async {
    final msgType = content['msg_type'] as String? ?? 'text';
    final msgData = content['data'] as Map<String, dynamic>?;
    final body = messagePreview(msgType: msgType, data: msgData);

    final convType = conversationType ?? '';
    final convTitle = conversationTitle ?? '';
    final isGroupConv = convType == 'group_user' || convType == 'group_mixed';
    final isAgentSession = convType == 'agent_session';
    final hasConvTitle = convTitle.isNotEmpty;
    final String notifTitle;
    final String notifBody;
    if (isAgentSession) {
      // title 走会话级(agent 名),body 不加前缀(单 agent 语义,前缀冗余)
      notifTitle = hasConvTitle ? convTitle : senderName;
      notifBody = body;
    } else if (isGroupConv && hasConvTitle) {
      notifTitle = convTitle;
      notifBody = '$senderName：$body';
    } else {
      notifTitle = senderName;
      notifBody = body;
    }

    try {
      // 加载头像 bitmap(内存缓存 → 文件缓存 → 下载 → 兜底色块)
      Uint8List? avatarBytes;
      final avatarUrl = senderAvatarUrl ?? _avatarUrls[senderId];
      if (_baseUrl != null && _token != null) {
        // loadAvatarBitmap 必返回非空(下载失败兜底色块),故用空合并直接赋值
        avatarBytes = _avatarBitmapCache[senderId] ??
            await loadAvatarBitmap(
              agentId: senderId,
              name: senderName,
              avatarUrl: avatarUrl,
              baseUrl: _baseUrl!,
              httpHeaders: {'Authorization': 'Bearer $_token'},
            );
        _avatarBitmapCache[senderId] = avatarBytes;
      }

      await _showNotification(
        payload: NotificationPayload(
          convId: convId,
          // user-user 消息 sender 是 user,agentId 字段作占位(点击路由用 convId)。
          agentId: senderId,
          // agentName 字段实际语义=「会话显示名」(单聊 sender / 群聊群名),
          // 仅 payload 反序列化兼容用,路由不再消费。
          agentName: notifTitle,
        ),
        title: notifTitle,
        body: notifBody,
        unreadCount: _unread.get(convId),
        avatarBytes: avatarBytes,
      );
    } catch (e) {
      debugLog('[bg-service] 通知发送失败: $e');
    }
  }

  /// 测试入口:注入一条原始 WS 帧,走与真实 WS 通道一致的 _handleMessage 路径。
  @visibleForTesting
  Future<void> handleRawMessageForTest(String raw) => _handleMessage(raw);

  /// 测试入口:读某会话的本地未读计数。
  @visibleForTesting
  int unreadForTest(String convId) => _unread.get(convId);

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
