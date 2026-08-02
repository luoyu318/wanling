import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../models/message.dart';
import '../models/ws_message.dart';
import '../utils/reconnect_backoff.dart';
import 'local_message_store_abstract.dart';

/// WebSocket 连接状态。banner 用 disconnected 显示「连接断开」。
enum ConnState {
  disconnected,
  connecting,
  connected,
}

class WebSocketService {
  /// F4: 本地消息持久化(可选)。注入后在 dispatch 分支调用,
  /// 失败 silently fallback(spec 错误处理矩阵)。默认 null 兼容现有测试。
  final LocalMessageStore? _store;

  /// token 刷新回调。_reconnect 重连前调用,如果返回新 token 则用它。
  /// 解决 token 过期但无 API 401 触发 refresh 的场景(用户开着 APP 不操作,
  /// 2h 后 token 过期,WS 重连被拒 → tokenRefresher 拿新 token → 重连成功)。
  /// 返回 null 表示无法刷新(无 refresh token / refresh 失败),用旧 token 重试。
  Future<String?> Function()? tokenRefresher;

  WebSocketService({LocalMessageStore? store}) : _store = store;

  WebSocketChannel? _channel;
  StreamSubscription? _channelSub;
  String? _token;
  String? _baseUrl;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  /// WS dispatch 的最新 seq 号,用于 Resume。
  ///
  /// F4 过渡态:Task 8 起写入 LocalMessageStore.global_last_seq,
  /// 但此处内存字段仅在 dispatch 分支被赋值,启动时尚未从 store 读取
  /// (Task 9 接入 hello 分支读 store.getGlobalLastSeq() 后才填充)。
  /// Task 9 完成后此字段优先读 store,fallback 内存。
  int? _lastSeq;
  // 防止重连风暴：connect 已经在排队/进行时，跳过新的 _reconnect 调用。
  bool _connecting = false;
  // disconnect 后不再重连。configure/connect 时清。
  bool _stopped = false;

  // 重连退避策略：固定 3s 改指数退避，避免服务恢复时重连风暴。
  final ReconnectBackoff _backoff = ReconnectBackoff();
  // 防 onError+onDone 双触发让 _reconnect 重复调度（吃两次 backoff attempt）。
  bool _reconnectScheduled = false;

  final _messageController = StreamController<WSMessage>.broadcast();
  Stream<WSMessage> get messages => _messageController.stream;

  /// TYPING_START 事件流。元素是 dispatch 的 d 字段({conversation_id})。
  /// ChatPage 经 typingProvider 订阅,按 conversation_id 跟踪 typing 状态。
  /// 设计：单列流而非复用 messages 流，避免 chatProvider 误把 TYPING_START
  /// 当 MESSAGE_CREATE 处理（messages 流只暴露给订阅 MESSAGE_CREATE 的消费者）。
  /// 非 final：F1 修复要求 disconnect→connect 复用时由 _ensureControllers 重建。
  StreamController<Map<String, dynamic>> _typingController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get typingStream => _typingController.stream;

  /// SESSION_STATUS 事件流（agent busy/retry/idle 状态）。
  /// 单列流，避免 chatProvider 把状态事件当 MESSAGE_CREATE 处理。
  /// 非 final：F1 修复要求 disconnect→connect 复用时由 _ensureControllers 重建。
  StreamController<Map<String, dynamic>> _sessionStatusController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get sessionStatusStream =>
      _sessionStatusController.stream;

  /// MESSAGE_UPDATE 事件流（审批状态变更推送等）。
  /// 单列流，避免 chatProvider 把 UPDATE 当 CREATE 重复插入消息列表。
  /// chatProvider 监听本流后按 d.id 定位已有消息做局部更新（如 approval 状态切换）。
  /// 非 final：F1 修复要求 disconnect→connect 复用时由 _ensureControllers 重建。
  StreamController<WSMessage> _messageUpdateController =
      StreamController<WSMessage>.broadcast();
  Stream<WSMessage> get messageUpdates => _messageUpdateController.stream;

  /// 会话管理事件流(N 方 participants 模型):
  /// CONVERSATION_PARTICIPANT_JOIN / LEAVE / UPDATE。
  /// conversationProvider 监听本流,本地增删 participants / 更新 title/avatar。
  /// 非 final：F1 修复要求 disconnect→connect 复用时由 _ensureControllers 重建。
  StreamController<WSMessage> _conversationUpdatesController =
      StreamController<WSMessage>.broadcast();
  Stream<WSMessage> get conversationUpdates =>
      _conversationUpdatesController.stream;

  /// 好友系统事件流:
  /// FRIEND_REQUEST_RECEIVED / DECIDED / REMOVED。
  /// friendProvider 监听本流,本地更新请求列表 / 好友列表 + 触发系统通知。
  /// 非 final：F1 修复要求 disconnect→connect 复用时由 _ensureControllers 重建。
  StreamController<WSMessage> _friendUpdatesController =
      StreamController<WSMessage>.broadcast();
  Stream<WSMessage> get friendUpdates => _friendUpdatesController.stream;

  /// MESSAGE_READ 多端同步事件流。
  /// A 设备 markRead 后 server 广播给该 user 全部 WS 连接,
  /// conversationProvider 监听刷徽章 → 0;chatProvider 监听刷 firstUnread。
  /// 非 final:F1 修复要求 disconnect→connect 复用时由 _ensureControllers 重建。
  StreamController<WSMessage> _messageReadController =
      StreamController<WSMessage>.broadcast();
  Stream<WSMessage> get messageReads => _messageReadController.stream;

  /// SESSION_META_UPDATE 事件流(agent_session 元数据实时刷新)。
  /// plugin 调 UpdateSessionMetaAsAgent 写库后,server 广播给本会话 user 端:
  /// payload = {conv_id, session_meta:{mode,model_id,...,cwd,git_branch}}。
  /// chatProvider 监听本流后用 session_meta 整体替换 chatState.sessionMeta,
  /// SessionMetaStrip / EnvMetaStrip 实时刷新,无需 2s 防抖拉 getConversation。
  StreamController<WSMessage> _sessionMetaUpdateController =
      StreamController<WSMessage>.broadcast();
  Stream<WSMessage> get sessionMetaUpdates =>
      _sessionMetaUpdateController.stream;

  /// op=14 STREAM 流式输出流(plugin→server→正在观看的 user)。
  /// delta 不入库(_persistToStore 仅在 dispatch 分支调用),不带 seq,
  /// 不推进 _lastSeq。非 final:F1 修复要求 disconnect→connect 复用时
  /// 由 _ensureControllers 重建。
  StreamController<Map<String, dynamic>> _streamController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get streamEvents => _streamController.stream;

  /// 测试钩子：暴露 controller 关闭状态，验证 F1 修复。
  @visibleForTesting
  bool get isTypingControllerClosed => _typingController.isClosed;

  @visibleForTesting
  bool get isMessageUpdateControllerClosed => _messageUpdateController.isClosed;

  @visibleForTesting
  bool get isConversationUpdatesControllerClosed =>
      _conversationUpdatesController.isClosed;

  @visibleForTesting
  bool get isFriendUpdatesControllerClosed => _friendUpdatesController.isClosed;

  @visibleForTesting
  bool get isMessageReadControllerClosed => _messageReadController.isClosed;

  @visibleForTesting
  bool get isSessionMetaUpdateControllerClosed =>
      _sessionMetaUpdateController.isClosed;

  @visibleForTesting
  bool get isStreamControllerClosed => _streamController.isClosed;

  /// 重建已关闭的 controller。connect() 入口自动调；测试直接调以验证行为。
  /// 公开为 visibleForTesting 是为了让测试不依赖真实网络连接（connect() 会
  /// 触发 WebSocketChannel.connect 真去握手，测试无法干净隔离）。
  @visibleForTesting
  void testEnsureControllers() => _ensureControllers();

  // 连接状态：private setter，对外只读 currentValue + 流。
  final _connStateController = StreamController<ConnState>.broadcast();
  Stream<ConnState> get connectionStateStream => _connStateController.stream;
  ConnState _currentConnState = ConnState.disconnected;
  ConnState get currentConnState => _currentConnState;

  /// 本地存储健康状态流。true=degraded(连续失败超阈值),false=recovered。
  /// UI 订阅后显示「本地存储异常」提示,让用户感知消息可能没持久化
  /// (磁盘满 / DB 损坏等场景 silent fallback 不再完全静默)。
  /// final:跟 _connStateController 一样,WS service 单例,不随 disconnect 重建。
  final _localStoreHealthController = StreamController<bool>.broadcast();
  Stream<bool> get localStoreHealthStream => _localStoreHealthController.stream;
  int _localStoreFailCount = 0;
  static const _localStoreFailThreshold = 3;

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

  /// 更新内存 token(token refresh 成功后调用)。
  ///
  /// 避免 wsProvider 重建断连:token refresh 时直接更新内存 token,
  /// 当前 WS 连接不断(长连接不重新验 token),下次重连自然用新 token。
  /// 如果 WS 已断开并在 backoff 等待中,更新 token 后下次重连直接用新 token。
  void updateToken(String token) {
    _token = token;
  }

  /// 重建被 disconnect() 关闭的 broadcast controller。
  ///
  /// 解决 F1：disconnect→connect 同实例复用时向已 close 的 controller
  /// 调 add 抛 StateError。
  ///
  /// **限制**：重建后是**新 controller 实例**，旧 subscribers（如 typingProvider
  /// 持有的 stream sub）指向已 close 的旧 stream，无法收新事件。生产路径靠
  /// wsProvider 整体 dispose+rebuild 兜底（旧 sub cancel、新 provider 重订阅）；
  /// 若未来出现「同实例手动 disconnect→connect」场景，调用方需自行重订阅。
  void _ensureControllers() {
    if (_typingController.isClosed) {
      _typingController = StreamController<Map<String, dynamic>>.broadcast();
    }
    if (_sessionStatusController.isClosed) {
      _sessionStatusController = StreamController<Map<String, dynamic>>.broadcast();
    }
    if (_messageUpdateController.isClosed) {
      _messageUpdateController = StreamController<WSMessage>.broadcast();
    }
    if (_conversationUpdatesController.isClosed) {
      _conversationUpdatesController = StreamController<WSMessage>.broadcast();
    }
    if (_friendUpdatesController.isClosed) {
      _friendUpdatesController = StreamController<WSMessage>.broadcast();
    }
    if (_messageReadController.isClosed) {
      _messageReadController = StreamController<WSMessage>.broadcast();
    }
    if (_sessionMetaUpdateController.isClosed) {
      _sessionMetaUpdateController = StreamController<WSMessage>.broadcast();
    }
    if (_streamController.isClosed) {
      _streamController = StreamController<Map<String, dynamic>>.broadcast();
    }
  }

  Future<void> connect() async {
    if (_baseUrl == null || _token == null) return;
    if (_connecting) return; // 防止并发 connect
    _connecting = true;
    _stopped = false;
    _ensureControllers(); // F1: 重建 disconnect 时关闭的 controller
    _setConnState(ConnState.connecting);

    // 先清掉旧 channel + subscription，避免新旧同时存在触发多次 onDone
    await _cleanupChannel();

    final wsUrl = _baseUrl!.replaceFirst('https://', 'wss://').replaceFirst('http://', 'ws://');
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

  Future<void> _handleMessage(WSMessage msg) async {
    switch (msg.op) {
      case OpCodes.hello:
        // 总是先 Identify：server ws_handler 要求首条消息必须是 Identify，
        // 否则直接关闭连接。即使 _lastSeq 有值（断线重连），也先 Identify
        // 让 server 注册 client，再补 Resume 拉取 missed messages。
        // server 重启后 buffer 为空，Resume 不会补到任何消息，无害。
        _connecting = false; // hello 到达，连接真正建立
        _backoff.reset(); // 连接成功，重置退避 attempt
        send(WSMessage(op: OpCodes.identify, d: {'token': _token}));

        // F4: last_seq 优先用内存值(断线重连场景),为 null 时从本地 DB 取
        // (启动场景:_lastSeq 还没被任何 dispatch 写过,从 store 兜底防进程
        // 被杀后 Resume last_seq=null 丢消息)。store 抛异常时 fallback null,
        // 不阻塞连接。
        int? resumeSeq = _lastSeq;
        final store = _store;
        if (resumeSeq == null && store != null) {
          try {
            resumeSeq = await store.getGlobalLastSeq();
          } catch (e) {
            debugPrint('[localdb] hello getGlobalLastSeq fail: $e');
          }
        }
        if (resumeSeq != null) {
          send(WSMessage(op: OpCodes.resume, d: {'last_seq': resumeSeq}));
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
      case OpCodes.stream:
        // op=14 流式快照:不落库、不带 seq、不进 _persistToStore。
        final d = msg.d as Map<String, dynamic>?;
        if (d != null) {
          final tlen = (d['text'] as String?)?.length ?? -1;
          debugPrint('[SSE-DBG] ws recv op=14 sid=${d['stream_id']} kind=${d['msg_type']} len=$tlen');
          _streamController.add(d);
        }
        return;
      case OpCodes.dispatch:
        // F4: 持久化到本地 DB(fire-and-forget,内部 async+await+try/catch 兜底)。
        // 放在分流之前:无论事件流向哪个 controller,store 都能记录。
        _persistToStore(msg);
        // TYPING_START 分流：单独暴露给 typingProvider，
        // 不进 messages 流（messages 流给 chatProvider 处理 MESSAGE_CREATE）。
        if (msg.t == 'TYPING_START') {
          final d = msg.d as Map<String, dynamic>?;
          if (d != null) {
            _typingController.add(d);
          }
          return;
        }
        // SESSION_STATUS 分流：agent busy/retry/idle 状态，单独暴露给 agentStatusProvider。
        if (msg.t == 'SESSION_STATUS') {
          final d = msg.d as Map<String, dynamic>?;
          if (d != null) {
            _sessionStatusController.add(d);
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
        // 会话管理事件分流(N 方 participants 模型):
        // CONVERSATION_PARTICIPANT_JOIN / LEAVE / UPDATE
        if (msg.t == 'CONVERSATION_PARTICIPANT_JOIN' ||
            msg.t == 'CONVERSATION_PARTICIPANT_LEAVE' ||
            msg.t == 'CONVERSATION_UPDATE') {
          if (msg.s != null) _lastSeq = msg.s;
          _conversationUpdatesController.add(msg);
          return;
        }
        // 好友系统事件分流:
        // FRIEND_REQUEST_RECEIVED / DECIDED / REMOVED
        if (msg.t == 'FRIEND_REQUEST_RECEIVED' ||
            msg.t == 'FRIEND_REQUEST_DECIDED' ||
            msg.t == 'FRIEND_REMOVED') {
          if (msg.s != null) _lastSeq = msg.s;
          _friendUpdatesController.add(msg);
          return;
        }
        // MESSAGE_READ 多端同步分流:
        // A 设备 markRead 后,server 广播给该 user 全部 WS 连接(含 A 自己)。
        // conversationProvider / chatProvider 监听本流刷本地状态。
        if (msg.t == 'MESSAGE_READ') {
          if (msg.s != null) _lastSeq = msg.s;
          _messageReadController.add(msg);
          return;
        }
        // SESSION_META_UPDATE 分流:agent_session 元数据(mode/model/cwd/git_branch)更新。
        // plugin PATCH /session-meta 后,server 写库 + 广播给本会话 user 端。
        // chatProvider 监听本流后整体替换 chatState.sessionMeta,实时刷新
        // SessionMetaStrip / EnvMetaStrip,不依赖 agent 消息触发 2s 防抖拉取。
        if (msg.t == 'SESSION_META_UPDATE') {
          if (msg.s != null) _lastSeq = msg.s;
          _sessionMetaUpdateController.add(msg);
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

  /// 发消息到指定会话（按 conversation_id 路由，N 方 participants 模型）。
  ///
  /// 协议 payload：`{conversation_id, content}`。server processor 优先解析
  /// conversation_id 直发到会话（校验 sender 是 participant）。
  /// 旧 agent_id 路由仍兼容（hermes adapter 用），APP 端统一走 conv_id。
  void sendMessage(String conversationId, Map<String, dynamic> content) {
    send(WSMessage(
      op: OpCodes.dispatch,
      t: 'MESSAGE_CREATE',
      d: {'conversation_id': conversationId, 'content': content},
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
    if (_reconnectScheduled) return; // 防 onError+onDone 双触发吃两次 attempt
    _reconnectScheduled = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    final delay = _backoff.next();
    debugPrint('[ws] 重连等待 ${delay.inMilliseconds}ms');
    _reconnectTimer = Timer(delay, () {
      _reconnectScheduled = false;
      if (_stopped) return;
      // 重连前尝试刷新 token:token 可能已过期(2h TTL),用旧 token 重连会被
      // server 拒绝导致死循环。tokenRefresher 调 API refresh,成功则用新 token。
      if (tokenRefresher != null && _token != null) {
        tokenRefresher!().then((newToken) {
          if (newToken != null) {
            _token = newToken;
          }
          if (_token != null) connect();
        }).catchError((e) {
          debugPrint('[ws] tokenRefresher 失败,用旧 token 重连: $e');
          if (_token != null) connect();
        });
      } else {
        if (_token != null) connect();
      }
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
    _backoff.reset();
    _reconnectScheduled = false;
    _setConnState(ConnState.disconnected);
    _typingController.close();
    _sessionStatusController.close();
    _messageUpdateController.close();
    _conversationUpdatesController.close();
    _friendUpdatesController.close();
    _messageReadController.close();
    _sessionMetaUpdateController.close();
    _streamController.close();
  }

  /// F4: 把 dispatch 事件持久化到 LocalMessageStore。
  ///
  /// 失败 silently fallback(spec 错误处理矩阵),不阻塞 UI。
  /// fire-and-forget:store 写入不 await,即使 DB 慢也不卡事件分发。
  ///
  /// async + await:store 各方法是 Future(异步 DB I/O),不 await 会让
  /// 真正的 I/O 异常逃逸 try/catch(debugPrint 不触发,排障盲区)。
  /// 调用方 `_handleMessage` 是 sync void,直接 fire-and-forget 此 Future,
  /// 异常由本方法内部 try/catch 兜住。
  ///
  /// 顺序说明(I3):fire-and-forget 模式下,两条 dispatch 的写入可能乱序完成
  /// (例如 seq=N 比 seq=N-1 先入库)。IM 场景按 created_at 排序回放,
  /// 不依赖写入顺序,可接受弱一致。global_last_seq 是单调 max 语义
  /// (setGlobalLastSeq 内部 `MAX(old, new)`),乱序到达也最终收敛到最大值。
  Future<void> _persistToStore(WSMessage msg) async {
    final store = _store;
    if (store == null) return;
    final d = msg.d as Map<String, dynamic>?;
    if (d == null) return;

    try {
      if (msg.s != null) {
        await store.setGlobalLastSeq(msg.s!);
      }
      switch (msg.t) {
        case 'MESSAGE_CREATE':
          final m = ChatMessage.fromJson(d);
          // 子 agent 事件(parent_msg_id 非空)不存 local DB:
          // subagent_detail_page 走 HTTP API(getSubagentMessages)不读本地,
          // 主聊天列表又需过滤它们,存下来反而制造过滤负担与脏数据风险。
          if (m.parentMsgId != null && m.parentMsgId!.isNotEmpty) break;
          await store.putMessage(m);
          break;
        case 'MESSAGE_UPDATE':
          final msgId = d['message_id'] as String?;
          final content = d['content'] as Map<String, dynamic>?;
          if (msgId != null && content != null) {
            await store.updateContent(msgId, content);
          }
          break;
        case 'MESSAGE_DELETE':
          final ids = (d['ids'] as List?)?.cast<String>() ?? [];
          final scope = (d['scope'] as String?) ?? 'hide';
          final senderName = d['sender_name'] as String? ?? '';
          if (scope == 'recall') {
            for (final id in ids) {
              await store.markRecalled(id, recalledByName: senderName);
            }
          } else {
            for (final id in ids) {
              await store.deleteMessage(id);
            }
          }
          break;
      }
      // 成功:重置计数。之前是 degraded(>= 阈值)的话 emit false 通知 UI 恢复。
      if (_localStoreFailCount >= _localStoreFailThreshold) {
        _localStoreHealthController.add(false);
      }
      _localStoreFailCount = 0;
    } catch (e, st) {
      _localStoreFailCount++;
      // 仅在首次跨过阈值时 emit true 一次,避免每条失败都广播。
      if (_localStoreFailCount == _localStoreFailThreshold) {
        _localStoreHealthController.add(true);
      }
      debugPrint('[localdb] _persistToStore fail (count=$_localStoreFailCount): $e\n$st');
    }
  }

  /// 测试钩子:直接调 _handleMessage 的 dispatch 分支(无真实 WS 连接)。
  /// F4: _handleMessage 已改 async(hello 分支读 store),本钩子返回 Future
  /// 让测试可 await 等待 store 写入完成。
  @visibleForTesting
  Future<void> testHandleDispatch(Map<String, dynamic> rawMsg) {
    final msg = WSMessage.fromJson(rawMsg);
    return _handleMessage(msg);
  }
}
