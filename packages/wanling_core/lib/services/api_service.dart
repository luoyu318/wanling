import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/approval.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/friendship.dart';
import 'package:wanling_core/models/login_result.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/pairing.dart';
import 'package:wanling_core/models/register_result.dart';
import 'package:wanling_core/models/slash_command.dart';
import 'package:wanling_core/models/agent_mode.dart';
import 'package:wanling_core/models/agent_preset.dart';
import 'package:wanling_core/models/rpc_method.dart';
import 'package:wanling_core/models/unread_info.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/models/user_summary.dart';
import 'api_response.dart';

class ApiService {
  final Dio _dio;
  final String baseUrl;

  /// 401 响应触发的回调，通常由 authProvider 在构造 notifier 后注入为「全局登出」。
  /// 设为可空：测试或独立使用 ApiService 时不需要登出。
  void Function()? _onUnauthorized;

  /// refresh 成功后的回调,通知 auth_provider 持久化新 token pair。
  /// 参数:(newAccessToken, newRefreshToken)。
  void Function(String access, String refresh)? _onTokenRefreshed;

  /// 当前 refresh token,由 auth_provider 在 login/restoreSession 后注入。
  /// null = 未登录或仅 access token 模式(任何 401 都直接登出)。
  String? _refreshToken;

  /// 并发 401 去重:同时多个请求收到 401,只发一个 refresh,其他等同一个 Future。
  /// 用 Future 而非 Completer:Future 自动把 error 传播给所有 awaiter,
  /// 无 Completer.completeError 的"unawaited future error"问题。
  Future<String>? _refreshInFlight;

  ApiService({required this.baseUrl}) : _dio = Dio(BaseOptions(baseUrl: baseUrl)) {
    _installInterceptor();
  }

  /// 测试用构造：注入外部 dio 实例，便于替换 HttpClientAdapter 进行 mock。
  @visibleForTesting
  ApiService.withDio(this._dio) : baseUrl = _dio.options.baseUrl {
    _installInterceptor();
  }

  /// 暴露 dio 实例供测试替换 adapter。
  Dio get dio => _dio;

  /// 注入 401 回调，避免在 ApiService 内部直接依赖 Riverpod / AuthNotifier。
  void setOnUnauthorized(void Function() cb) {
    _onUnauthorized = cb;
  }

  /// 注入 refresh 成功回调,auth_provider 用于持久化新 token pair。
  void setOnTokenRefreshed(void Function(String access, String refresh) cb) {
    _onTokenRefreshed = cb;
  }

  /// 注入当前 refresh token(由 auth_provider 在 login/restoreSession 后调用)。
  void setRefreshToken(String? token) {
    _refreshToken = token;
  }

  /// 安装 envelope 拦截器:
  /// - onResponse: 成功响应剥 `{ok:true, data:...}` envelope,业务层拿到 data
  /// - onResponse: `ok:false` 构造 ApiException reject(透传给业务层 throwsA)
  /// - onError: 4xx/5xx body 含 envelope error 提取 code/message 包到 ApiException
  /// - onError: 401 先尝试 refresh(并发去重),成功则重试原请求;失败才触发全局登出
  /// - binary / 非 Map 响应透传(文件下载场景)
  void _installInterceptor() {
    _dio.interceptors.add(InterceptorsWrapper(
      onResponse: (response, handler) {
        // 仅处理 JSON Map 响应(文件下载 binary 透传)
        if (response.data is Map<String, dynamic>) {
          final body = response.data as Map<String, dynamic>;
          final ok = body['ok'] as bool?;
          if (ok == true) {
            // 剥 envelope,业务层直接拿到 data
            response.data = body['data'];
            handler.next(response);
            return;
          }
          if (ok == false) {
            // 后端 envelope 失败响应,构造 ApiException reject 给业务层
            final err = body['error'] as Map<String, dynamic>?;
            handler.reject(
              DioException(
                requestOptions: response.requestOptions,
                response: response,
                error: ApiException(
                  err?['code'] as String? ?? 'internal_error',
                  err?['message'] as String? ?? '未知错误',
                  statusCode: response.statusCode,
                ),
              ),
              true,
            );
            return;
          }
          // ok 字段缺失: 非 envelope 响应(理论上不该出现),透传
        }
        handler.next(response);
      },
      onError: (e, handler) async {
        // 防 refresh 请求自身的 401 触发递归:refresh 请求打 isRefresh 标记,
        // 收到任何错误直接透传(由 _doRefresh 的 caller 处理)。
        if (e.requestOptions.extra['isRefresh'] == true) {
          handler.next(e);
          return;
        }

        // 401 自动 refresh + 重试(单次重试,retried 标记防无限循环)
        if (e.response?.statusCode == 401 &&
            e.requestOptions.extra['retried'] != true &&
            _refreshToken != null) {
          String newToken;
          try {
            newToken = await _doRefresh();
          } catch (_) {
            // refresh 失败:登出 + 透传原始 401 错误
            _onUnauthorized?.call();
            handler.next(_wrapError(e));
            return;
          }
          // refresh 成功,重试原请求(单次)
          e.requestOptions.headers['Authorization'] = 'Bearer $newToken';
          e.requestOptions.extra['retried'] = true;
          try {
            final response = await _dio.fetch(e.requestOptions);
            handler.resolve(response);
            return;
          } catch (retryError) {
            // 重试失败:retry 的 onError 已处理(若 401 已登出),透传 retry 错误
            // retryError 已是 _wrapError 包装过的 DioException
            handler.next(retryError is DioException ? retryError : e);
            return;
          }
        }

        // 非 refresh-able 401(无 refresh_token / 已重试过) 或非 401 错误:走原始逻辑
        if (e.response?.statusCode == 401) {
          _onUnauthorized?.call();
        }
        handler.next(_wrapError(e));
      },
    ));
  }

  /// 把 DioException 的 envelope error 提取成 ApiException 包装的新 DioException。
  /// 非 envelope body 保持原样透传。
  DioException _wrapError(DioException e) {
    final data = e.response?.data;
    if (data is Map<String, dynamic> && data['ok'] == false) {
      final err = data['error'] as Map<String, dynamic>?;
      final code = err?['code'] as String? ?? 'internal_error';
      final message = err?['message'] as String? ?? '未知错误';
      return DioException(
        type: e.type,
        message: message,
        requestOptions: e.requestOptions,
        response: e.response,
        error: ApiException(code, message, statusCode: e.response?.statusCode),
      );
    }
    return e;
  }

  /// 内部 refresh 实现,带并发去重。
  /// 多个 401 同时进来,只发一次 POST /api/auth/refresh,共享同一个 Future。
  /// 成功:更新 _refreshToken + dio Authorization header + 触发 _onTokenRefreshed 回调。
  /// 失败:抛出异常,caller 决定后续(401 拦截器 catch 后登出)。
  Future<String> _doRefresh() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final future = _performRefresh();
    _refreshInFlight = future;
    return future;
  }

  Future<String> _performRefresh() async {
    final refresh = _refreshToken;
    if (refresh == null) {
      throw StateError('no refresh token');
    }
    try {
      final res = await _dio.post(
        '/api/auth/refresh',
        data: {'refresh_token': refresh},
        options: Options(extra: const {'isRefresh': true}),
      );
      final newAccess = res.data['token'] as String;
      final newRefresh = res.data['refresh_token'] as String;
      _refreshToken = newRefresh;
      setToken(newAccess);
      _onTokenRefreshed?.call(newAccess, newRefresh);
      return newAccess;
    } finally {
      _refreshInFlight = null;
    }
  }

  void setToken(String token) {
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  /// 尝试刷新 access token(供 WebSocketService.tokenRefresher 调用)。
  ///
  /// 与 401 拦截器的 _doRefresh 共享同一并发去重 Future,
  /// 成功返新 access token,失败返 null(不抛异常,调用方靠 null 判断)。
  /// 内部已触发 _onTokenRefreshed 回调,auth_provider 会持久化 + 更新 state。
  Future<String?> tryRefreshToken() async {
    if (_refreshToken == null) return null;
    try {
      return await _doRefresh();
    } catch (e) {
      debugPrint('[api] tryRefreshToken 失败: $e');
      return null;
    }
  }

  /// 清除 Authorization 头(logout 后调,防在飞请求携带失效 token)。
  void clearToken() {
    _dio.options.headers.remove('Authorization');
  }

  /// 主动调 server 登出(POST /api/auth/logout)。
  /// 黑名单当前 access token + 删 refresh token。
  /// 失败吞掉异常:登出失败不阻塞本地清理(auth_provider 会无脑清本地 state)。
  Future<void> logout() async {
    try {
      await _dio.post('/api/auth/logout', data: {
        if (_refreshToken != null) 'refresh_token': _refreshToken,
      });
    } catch (_) {}
  }

  Future<RegisterResult> register(String username, String password) async {
    final res = await _dio.post('/api/auth/register', data: {
      'username': username,
      'password': password,
    });
    return RegisterResult.fromJson(res.data as Map<String, dynamic>);
  }

  Future<LoginResult> login(String username, String password) async {
    final res = await _dio.post('/api/auth/login', data: {
      'username': username,
      'password': password,
    });
    return LoginResult.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<Agent>> getAgents() async {
    final res = await _dio.get('/api/agents');
    return (res.data as List)
        .map((e) => Agent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 拉取指定 agent 名下的 agent_session 会话列表(user 视角,二级入口)。
  ///
  /// server Task 8 起在 userAuth 下提供 `GET /api/agents/:agentId/sessions`,
  /// 返回该 user 参与的、属于该 agent 的 agent_session 会话数组(走 envelope
  /// 拦截器剥 {ok:true,data:[...]} 后 res.data 直接是 list)。
  Future<List<Conversation>> getAgentSessions(String agentId) async {
    final res = await _dio.get('/api/agents/$agentId/sessions');
    return (res.data as List)
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 拉取某 agent 的可选模型清单（plugin 上报、server 内存缓存）。
  /// 空清单也是合法态（plugin 未上报 / server 重启）。
  Future<List<AgentModel>> getAgentModels(String agentId) async {
    final res = await _dio.get('/api/agents/$agentId/models');
    final body = res.data as Map<String, dynamic>;
    final models = body['models'] as List? ?? [];
    return models
        .map((e) => AgentModel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 拉取某 agent 的命令清单(plugin 上报、server 内存缓存)。
  /// 空清单是合法态(plugin 未上报 / server 重启)。
  Future<List<SlashCommand>> getAgentSlashCatalog(String agentId) async {
    final res = await _dio.get('/api/agents/$agentId/slash-catalog');
    final body = res.data as Map<String, dynamic>;
    final commands = body['commands'] as List? ?? [];
    return commands
        .map((e) => SlashCommand.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 拉取某 agent 的模式清单(plugin 上报、server 内存缓存)。
  /// 空清单是合法态(无模式概念的 plugin 未上报 / server 重启)。
  /// 渲染时按 session-meta mode id 查清单取 label/style。
  Future<List<AgentMode>> getAgentModes(String agentId) async {
    final res = await _dio.get('/api/agents/$agentId/modes');
    final body = res.data as Map<String, dynamic>;
    final modes = body['modes'] as List? ?? [];
    return modes
        .map((e) => AgentMode.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 拉取某 agent 的预设清单(plugin 上报、server 内存缓存)。
  /// 空清单是合法态(无预设概念的 plugin 不上报,APP 隐藏选择步骤)。
  Future<List<AgentPreset>> getAgentPresets(String agentId) async {
    final res = await _dio.get('/api/agents/$agentId/presets');
    final body = res.data as Map<String, dynamic>;
    final presets = body['presets'] as List? ?? [];
    return presets
        .map((e) => AgentPreset.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 拉取某 agent 的 RPC 方法清单(plugin 上报、server 内存缓存)。
  /// 空清单是合法态(plugin 未上报 / server 重启)。
  Future<List<RpcMethod>> getRpcMethods(String agentId) async {
    final res = await _dio.get('/api/agents/$agentId/rpc-methods');
    final body = res.data as Map<String, dynamic>;
    final methods = body['methods'] as List? ?? [];
    return methods
        .map((e) => RpcMethod.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Agent> createAgent(String name, {String type = ''}) async {
    final res = await _dio.post('/api/agents', data: {
      'name': name,
      if (type.isNotEmpty) 'type': type,
    });
    return Agent.fromJson(res.data as Map<String, dynamic>);
  }

  Future<Agent> updateAgent(
    String id, {
    String? name,
    String? avatarUrl,
    String? bio,
    String? type,
  }) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (avatarUrl != null) data['avatar_url'] = avatarUrl;
    if (bio != null) data['bio'] = bio;
    if (type != null) data['type'] = type;
    final res = await _dio.put('/api/agents/$id', data: data);
    return Agent.fromJson(res.data as Map<String, dynamic>);
  }

  Future<void> deleteAgent(String id) async {
    await _dio.delete('/api/agents/$id');
  }

  /// 重置 agent 密钥,返回新密钥(仅此一次可见,对齐 GitHub PAT 模式)。
  /// 旧连接立即失效,用户需用新 key 重新配置 Agent 终端。
  Future<String> rotateAgentSecret(String id) async {
    final res = await _dio.post('/api/agents/$id/rotate-secret');
    final data = res.data as Map<String, dynamic>;
    return data['secret_key'] as String;
  }

  /// 扫码配对：app 扫码后调用，拉取当前 user 名下 agent 列表。
  /// 返回 PairScanResult（status 非 null 表示票据异常如 expired）。
  ///
  /// server 两种响应形态（envelope 化后）：
  /// - 正常：data 直接是 agent 摘要数组
  /// - 票据异常（expired/not_found）：data 是 map 含 status 字段
  Future<PairScanResult> pairScan(String ticketId) async {
    final res = await _dio.post('/api/pair/tickets/$ticketId/scan');
    if (res.data is List) {
      final agents = (res.data as List)
          .map((e) => PairAgentSummary.fromJson(e as Map<String, dynamic>))
          .toList();
      return PairScanResult(agents: agents);
    }
    return PairScanResult.fromJson(res.data as Map<String, dynamic>);
  }

  /// 扫码配对：选已有 agent（agentId）或新建（newAgentName）。
  /// 二选一：agentId 非空走选已有（会重置 key），否则用 newAgentName 新建。
  Future<PairCompleteResult> pairComplete(
    String ticketId, {
    String? agentId,
    String? newAgentName,
  }) async {
    final data = <String, dynamic>{};
    if (agentId != null) {
      data['agent_id'] = agentId;
    } else if (newAgentName != null) {
      data['new_agent_name'] = newAgentName;
    }
    final res = await _dio.post('/api/pair/tickets/$ticketId/complete', data: data);
    return PairCompleteResult.fromJson(res.data as Map<String, dynamic>);
  }

  Future<List<Conversation>> getConversations() async {
    final res = await _dio.get('/api/conversations');
    return (res.data as List)
        .map((e) => Conversation.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Conversation> findOrCreateConversation(String agentId) async {
    final res = await _dio.post('/api/conversations', data: {'agent_id': agentId});
    return Conversation.fromJson(res.data as Map<String, dynamic>);
  }

  // === N 方 participants 模型 API ===

  /// 创建会话(支持 4 种 type + group_mixed 群聊)。
  ///
  /// member_ids / member_types 一一对应(同长度数组)。
  /// type=dm_user_user 时优先用 memberUsernames（client 不持 user_id 防枚举，
  /// server 会前置校验好友关系,非好友返 403）。
  /// type=group_user/group_mixed 时 title/avatarUrl 可填(群聊用)。
  /// type=agent_session 时 directory 可填(OC session 工作目录,创建时固化到
  /// conversations.directory 一级列,后续不再随 session_meta 变化)。
  Future<Conversation> createConversation({
    required String type,
    List<String> memberIds = const [],
    List<String> memberTypes = const [],
    List<String> memberUsernames = const [],
    String? title,
    String? avatarUrl,
    String? directory,
  }) async {
    final res = await _dio.post('/api/conversations', data: {
      'type': type,
      'member_ids': memberIds,
      'member_types': memberTypes,
      if (memberUsernames.isNotEmpty) 'member_usernames': memberUsernames,
      if (title != null) 'title': title,
      if (avatarUrl != null) 'avatar_url': avatarUrl,
      if (directory != null && directory.isNotEmpty) 'directory': directory,
    });
    return Conversation.fromJson(res.data as Map<String, dynamic>);
  }

  /// 单会话详情(含 participants[] 摘要 + 群元信息)。
  Future<Conversation> getConversation(String convId) async {
    final res = await _dio.get('/api/conversations/$convId');
    return Conversation.fromJson(res.data as Map<String, dynamic>);
  }

  /// 更新群名 / 群头像(owner / admin 才有权限)。
  Future<void> updateConversation(String convId,
      {String? title, String? avatarUrl}) async {
    await _dio.patch('/api/conversations/$convId', data: {
      if (title != null) 'title': title,
      if (avatarUrl != null) 'avatar_url': avatarUrl,
    });
  }

  /// 邀请成员加入会话(所有 role 都可邀请)。
  Future<void> inviteMember(
      String convId, String memberId, String memberType) async {
    await _dio.post('/api/conversations/$convId/participants', data: {
      'member_id': memberId,
      'member_type': memberType,
    });
  }

  /// 踢人(owner / admin,且不能踢 owner)。
  Future<void> kickMember(String convId, String memberId) async {
    await _dio.delete('/api/conversations/$convId/participants/$memberId');
  }

  /// 退群(所有 role 可调;owner 退群 → 销群)。
  Future<void> leaveConversation(String convId) async {
    await _dio.post('/api/conversations/$convId/leave');
  }

  // === 好友系统 API ===

  /// 按 username 模糊搜索(server 响应不含 user_id 防枚举)。
  Future<List<UserSummary>> searchUsers(String username) async {
    final res = await _dio.get(
      '/api/users/search',
      queryParameters: {'username': username},
    );
    return (res.data as List)
        .map((e) => UserSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 按 username 查用户详情（返 UserSummary，不含 user_id）。
  /// 用于「用户详情页」按 username 拉对方资料。404 时抛 DioException。
  Future<UserSummary> getUserByUsername(String username) async {
    final res = await _dio.get('/api/users/by-username/$username');
    return UserSummary.fromJson(res.data as Map<String, dynamic>);
  }

  /// 发起好友请求(body 用 username,不暴露 user_id)。
  ///
  /// server 响应字段是 to_user（无 created_at）,APP FriendRequest model
  /// 期望 user + created_at。这里把 to_user 重映射成 user,created_at
  /// 用当前时间填充（与原 friend_provider 行为一致,后续列表刷新会拿到真实时间）。
  Future<FriendRequest> createFriendRequest(String toUsername) async {
    final res = await _dio.post('/api/users/me/friend-requests', data: {
      'to_username': toUsername,
    });
    final raw = res.data as Map<String, dynamic>;
    final mapped = <String, dynamic>{
      'request_id': raw['request_id'],
      'status': raw['status'],
      'created_at': raw['created_at'] ?? DateTime.now().toIso8601String(),
      'user': raw['to_user'],
    };
    return FriendRequest.fromJson(mapped);
  }

  /// 收到的好友请求(pending,我是接收方)。
  Future<List<FriendRequest>> listIncomingFriendRequests() async {
    final res = await _dio.get('/api/users/me/friend-requests/incoming');
    return (res.data as List)
        .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 发出的好友请求(pending,我是发起方)。
  Future<List<FriendRequest>> listOutgoingFriendRequests() async {
    final res = await _dio.get('/api/users/me/friend-requests/outgoing');
    return (res.data as List)
        .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 好友列表(accepted)。
  Future<List<UserSummary>> listFriends() async {
    final res = await _dio.get('/api/users/me/friends');
    return (res.data as List)
        .map((e) => UserSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 接受好友请求(我是接收方)。
  Future<void> acceptFriendRequest(String requestId) async {
    await _dio.post('/api/friend-requests/$requestId/accept');
  }

  /// 拒绝好友请求(我是接收方)。
  Future<void> rejectFriendRequest(String requestId) async {
    await _dio.post('/api/friend-requests/$requestId/reject');
  }

  /// 删除好友(任一方都可)。
  ///
  /// 路径参数用 username(spec §4.2:client 不持有 user_id 防泄漏),
  /// server 内部 username → user_id 反查 + 调 FriendshipRepo.RemoveFriend。
  Future<void> removeFriend(String friendUsername) async {
    await _dio.delete('/api/users/me/friends/$friendUsername');
  }


  /// 标记会话已读：unread_count 清零。进入 ChatPage 时调一次。
  Future<void> markConversationRead(String convId) async {
    await _dio.post('/api/conversations/$convId/read');
  }

  /// 批量按 messageId 标记已读 + server 重算 unread_count。
  /// 用于「用户上滑阅读未读消息时按 messageId 同步进度」。
  /// 返回 server 重算后的剩余未读数（record type）。
  Future<({int unreadCount})> markMessagesRead(
      String convId, List<String> messageIds) async {
    final res = await _dio.post(
      '/api/conversations/$convId/messages/read',
      data: {'message_ids': messageIds},
    );
    final data = res.data as Map<String, dynamic>?;
    return (unreadCount: (data?['unread_count'] as num?)?.toInt() ?? 0);
  }

  /// 停止生成：user 点击停止按钮 → server dispatch GENERATION_ABORT 给 agent(plugin)。
  /// 幂等：无生成在跑时 server/plugin 侧优雅忽略。
  Future<void> abortGeneration(String convId) async {
    await _dio.post('/api/conversations/$convId/abort');
  }

  /// 获取会话未读信息（未读数 + 第一条未读消息 id + createdAt）。
  /// 进入 ChatPage 时调用，用于定位未读消息。
  Future<UnreadInfo> getUnreadInfo(String convId) async {    final res = await _dio.get('/api/conversations/$convId/unread');
    return UnreadInfo.fromJson(res.data as Map<String, dynamic>);
  }

  /// 游标分页拉取历史消息。
  /// [before] 为指定时间戳（RFC3339），返回 created_at < before 的消息。
  /// 不传 before 时返回最新 limit 条。
  Future<List<ChatMessage>> getMessagesBefore(
    String conversationId, {
    DateTime? before,
    int limit = 20,
  }) async {
    final params = <String, dynamic>{'limit': limit};
    if (before != null) {
      params['before'] = before.toUtc().toIso8601String();
    }
    final res = await _dio.get(
      '/api/conversations/$conversationId/messages',
      queryParameters: params,
    );
    final list = res.data as List<dynamic>;
    return list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获取子 agent 详细过程消息（按 root_msg_id 拉子树）。
  /// 用于「展开子 agent 任务卡片」时回填该 root 下的全部子 agent 事件流。
  Future<List<ChatMessage>> getSubagentMessages(
    String conversationId,
    String rootMsgId, {
    int limit = 100,
  }) async {
    final res = await _dio.get(
      '/api/conversations/$conversationId/messages',
      queryParameters: {
        'root_msg_id': rootMsgId,
        'limit': limit,
      },
    );
    final list = res.data as List<dynamic>;
    return list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 游标分页拉取"未读方向"消息（created_at > after）。
  /// 服务端返回 ASC（最老在前），调用方按需 reverse。
  /// 用于进入会话定位第一条未读：firstUnread + 之后的 N-1 条。
  Future<List<ChatMessage>> getMessagesAfter(
    String conversationId, {
    required DateTime after,
    int limit = 20,
  }) async {
    final res = await _dio.get(
      '/api/conversations/$conversationId/messages',
      queryParameters: {
        'limit': limit,
        'after': after.toUtc().toIso8601String(),
      },
    );
    final list = res.data as List<dynamic>;
    return list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 置顶会话。
  Future<void> pinConversation(String convId) async {
    await _dio.post('/api/conversations/$convId/pin');
  }

  /// 取消置顶。
  Future<void> unpinConversation(String convId) async {
    await _dio.delete('/api/conversations/$convId/pin');
  }

  /// 软删除会话(列表不显示,聊天记录保留,新消息自动恢复)。
  Future<void> hideConversation(String convId) async {
    await _dio.delete('/api/conversations/$convId');
  }

  Future<List<ChatMessage>> getMessages(String conversationId, {int limit = 50, int offset = 0}) async {
    final res = await _dio.get('/api/conversations/$conversationId/messages',
      queryParameters: {'limit': limit, 'offset': offset});
    final list = res.data as List<dynamic>;
    return list
        .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 删除/撤回单条消息。DELETE /api/messages/:id?scope=hide|recall
  /// scope=hide (默认):对自己隐藏(per-participant 维度)。
  /// scope=recall:撤回(deleted_at 全局软删,仅自己发的 + 5min 内)。
  Future<void> deleteMessage(String id, {String scope = 'hide'}) async {
    await _dio.delete(
      '/api/messages/$id',
      queryParameters: {'scope': scope},
    );
  }

  /// 发送消息(HTTP 同步接口)。
  ///
  /// 与老 WS 路径(ws.sendMessage)的差异:HTTP 同步返 server message_id + created_at,
  /// client 端可立即用 server id 替换乐观消息的 local id,撤回/编辑无 ID 不同步问题。
  ///
  /// 失败抛 DioException,调用方(ChatNotifier.sendText/sendFile)负责切 status=failed。
  Future<({String messageId, DateTime createdAt})> sendMessage(
    String conversationId,
    Map<String, dynamic> content,
  ) async {
    final resp = await _dio.post('/api/messages', data: {
      'conversation_id': conversationId,
      'content': content,
    });
    return (
      messageId: resp.data['message_id'] as String,
      createdAt: DateTime.parse(resp.data['created_at'] as String),
    );
  }

  /// 批量隐藏消息。POST /api/messages/batch-delete  body: {"ids":[...]}
  /// 仅支持 hide scope(批量撤回歧义太大,本期不开)。
  /// 返回服务端实际隐藏的条数。
  Future<int> batchDeleteMessages(List<String> ids) async {
    final res = await _dio.post(
      '/api/messages/batch-delete',
      data: {'ids': ids},
    );
    return res.data['deleted'] as int;
  }

  /// 跨页跳转:拉取 target 消息 + 前后 N 条上下文。
  ///
  /// GET /api/messages/:id/context?before=N&after=N
  ///
  /// 用于用户点击引用块后,客户端拉一段上下文单独渲染(Task 16 chat_page 跳转
  /// 会调本方法)。server 已 envelope 化,拦截器自动剥 {ok:true,data:{target,
  /// before, after}} 后业务层直接拿到内层 map。
  ///
  /// - [before] / [after]:上下文条数,默认 10。server 上限 50,负数归零。
  /// - 返回 [MessageContext]:before 时间倒序(最新在前),after 时间正序(最老在前),
  ///   与 server 排序一致。
  /// - target 不存在 / 已撤回 → [MessageNotFoundException]
  /// - 非 participant → [NoAccessException]
  /// - 其他 envelope error(internal_error 等)原样抛 [DioException]
  Future<MessageContext> getMessageContext(
    String messageId, {
    int before = 10,
    int after = 10,
  }) async {
    try {
      final res = await _dio.get(
        '/api/messages/$messageId/context',
        queryParameters: {
          'before': before,
          'after': after,
        },
      );
      // 拦截器已剥 envelope,res.data 即 {target, before, after}
      final data = res.data as Map<String, dynamic>;
      return MessageContext(
        target: ChatMessage.fromJson(data['target'] as Map<String, dynamic>),
        before: ((data['before'] as List?) ?? const [])
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
        after: ((data['after'] as List?) ?? const [])
            .map((m) => ChatMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
    } on DioException catch (e) {
      // 拦截器把 envelope error 包成 ApiException,按 code 映射专用异常
      final code = (e.error as ApiException?)?.code;
      if (code == 'not_found') throw MessageNotFoundException();
      if (code == 'forbidden') throw NoAccessException();
      rethrow;
    }
  }

  /// 上传文件。
  ///
  /// [convId] 可选:消息附件场景传当前会话 ID,server 写 file_conv_links
  /// 让该会话所有 participant 都能下载(防 IDOR 阻断接收方加载)。
  /// 头像上传不传(走 server 头像白名单)。详见 server file_handler。
  Future<String> uploadFile(String filePath, {String? convId}) async {
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath),
    });
    final url = convId == null ? '/api/upload' : '/api/upload?conversation_id=$convId';
    final res = await _dio.post(url, data: formData);
    return res.data['id'];
  }

  /// 上传内存中的图片字节（crop_your_image 裁剪结果是 Uint8List，无磁盘路径）。
  /// fileName 仅用于设置 Content-Disposition，不影响服务端存储。
  /// convId 非空时让 server 落 file_conv_links 授权记录(让同会话 participant 可下载,
  /// 群头像 / 群文件等场景用)。
  Future<String> uploadBytes(Uint8List bytes,
      {required String fileName, String? convId}) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: fileName),
    });
    final url = convId == null ? '/api/upload' : '/api/upload?conversation_id=$convId';
    final res = await _dio.post(url, data: formData);
    return res.data['id'];
  }

  Future<User> getMe() async {
    final res = await _dio.get('/api/users/me');
    return User.fromJson(res.data as Map<String, dynamic>);
  }

  /// 修改当前登录用户的密码。不需要旧密码（JWT 已验证身份）。
  /// 改密成功后 server 返新 token pair（旧 token 因 tokenver 自增已失效）。
  /// 返回 (token, refreshToken) 供调用方持久化 + 更新 api 实例。
  Future<({String token, String refreshToken})> changePassword(
      String newPassword) async {
    final res = await _dio.put('/api/users/me/password', data: {
      'new_password': newPassword,
    });
    return (
      token: res.data['token'] as String,
      refreshToken: res.data['refresh_token'] as String,
    );
  }

  /// 更新当前用户资料（部分更新）。
  /// nickname/bio: null=不传，""=清空。
  /// avatarUrl: null=不传，""=被后端忽略（不清空）。
  /// 返回更新后的 User。
  Future<User> updateMe({
    String? nickname,
    String? bio,
    String? avatarUrl,
  }) async {
    final data = <String, dynamic>{};
    if (nickname != null) data['nickname'] = nickname;
    if (bio != null) data['bio'] = bio;
    if (avatarUrl != null) data['avatar_url'] = avatarUrl;
    final res = await _dio.put('/api/users/me', data: data);
    return User.fromJson(res.data as Map<String, dynamic>);
  }

  /// 决策审批。actionId 必须是卡片 actions 列表内的合法 id。
  /// answers 仅 question 卡的 answer 动作携带（选中选项 id 列表）。
  /// 返回 null 表示成功（HTTP 200），非 null 为错误文案。
  Future<String?> decideApproval(String approvalId, String actionId,
      {String? reason, List<String>? answers}) async {
    try {
      await _dio.post('/api/approvals/$approvalId/decide', data: {
        'action_id': actionId,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        if (answers != null) 'answers': answers,
      });
      return null;
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code == 409) return '审批已被处理';
      if (code == 403) return '无权决策此审批';
      if (code == 404) return '审批不存在';
      return '决策失败：${e.message ?? '网络错误'}';
    }
  }

  /// 查审批详情（兜底，WS 推送丢失时主动查）
  Future<Approval?> getApproval(String approvalId) async {
    try {
      final res = await _dio.get('/api/approvals/$approvalId');
      return Approval.fromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      final code = (e.error as ApiException?)?.code;
      if (code == 'not_found') return null;
      rethrow;
    }
  }

  /// 调用 plugin RPC(POST /api/agents/:id/rpc)。
  ///
  /// server 走 JSON-RPC 2.0 envelope(非 wanling REST envelope),响应形态:
  /// - 成功(HTTP 200): `{"result": <T>}`,本方法返回内层 `result` map
  /// - plugin 失败(HTTP 503/504): `{"error": {"code": <int>, "message": "..."}}`,
  ///   抛 [RpcException] 携带原始 int code(-32001/-32002/-32003 等)
  /// - pre-RPC 校验失败(not_found/forbidden/bad_request): 走 wanling REST
  ///   envelope,会被 _wrapError 包成 [DioException] 透传
  ///
  /// [timeoutMs] 为 null/0/负值时用 server 端兜底 60s;正值时取 min(60s, timeoutMs)。
  Future<Map<String, dynamic>> rpc(
    String agentId,
    String method,
    Map<String, dynamic> params, {
    int? timeoutMs,
  }) async {
    final body = <String, dynamic>{
      'method': method,
      'params': params,
    };
    if (timeoutMs != null) body['timeout_ms'] = timeoutMs;

    try {
      final res = await _dio.post(
        '/api/agents/$agentId/rpc',
        data: body,
      );
      return ((res.data as Map)['result']) as Map<String, dynamic>;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      // RPC 协议失败:JSON-RPC envelope error(int code),与 REST envelope(String code)区分
      if (status == 503 || status == 504) {
        final err = (e.response?.data as Map?)?['error'] as Map<String, dynamic>?;
        throw RpcException(
          code: (err?['code'] as num?)?.toInt() ?? 0,
          message: err?['message'] as String? ?? 'rpc failed',
          statusCode: status,
        );
      }
      // 非 RPC 协议错误(not_found/forbidden/internal_error 等)走 _wrapError
      throw _wrapError(e);
    }
  }
}

/// 跨页跳转上下文:target + 前后 N 条消息。
///
/// - [target]:用户点击引用块要跳转到的目标消息(已 SanitizeForClient)。
/// - [before]:target 之前的消息,**时间倒序**(最新在前)。与 server 排序一致,
///   client 渲染时按需 reverse 成 ASC。
/// - [after]:target 之后的消息,**时间正序**(最老在前)。
class MessageContext {
  final ChatMessage target;
  final List<ChatMessage> before;
  final List<ChatMessage> after;

  const MessageContext({
    required this.target,
    required this.before,
    required this.after,
  });
}

/// 跨页跳转目标不存在 / 已撤回(server code=`not_found`,HTTP 404)。
///
/// 撤回消息跳转无意义,server 显式返 404,client 端可据此提示「消息已被删除」。
class MessageNotFoundException implements Exception {
  const MessageNotFoundException();
  @override
  String toString() => 'MessageNotFoundException';
}

/// 跨页跳转目标存在但当前用户非该会话 participant(server code=`forbidden`,HTTP 403)。
class NoAccessException implements Exception {
  const NoAccessException();
  @override
  String toString() => 'NoAccessException';
}

/// RPC 调用失败(server 走 JSON-RPC 2.0 envelope,非 wanling REST envelope)。
///
/// 携带原始 JSON-RPC int code(详见 server rpc_handler.go):
/// - -32001 plugin_offline: plugin WS 不在线(HTTP 503)
/// - -32002 plugin_timeout: ctx 超时,plugin 没在窗口内回包(HTTP 504)
/// - -32003 plugin_disconnected: 等待中 plugin WS 断线(HTTP 503)
///
/// 与 [ApiException](REST envelope,String code)区分,caller 可 `catch (RpcException)`
/// 单独处理 RPC 协议错误。
class RpcException implements Exception {
  final int code;
  final String message;
  final int? statusCode;

  const RpcException({
    required this.code,
    required this.message,
    this.statusCode,
  });

  @override
  String toString() => 'RpcException($code): $message';
}
