import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/pairing.dart';

class ApiService {
  final Dio _dio;
  final String baseUrl;

  /// 401 响应触发的回调，通常由 authProvider 在构造 notifier 后注入为「全局登出」。
  /// 设为可空：测试或独立使用 ApiService 时不需要登出。
  void Function()? _onUnauthorized;

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

  /// 安装 401 拦截器：响应状态码为 401 时触发全局登出回调，
  /// 然后照常把错误传下去（业务侧仍能 catch DioException）。
  void _installInterceptor() {
    _dio.interceptors.add(InterceptorsWrapper(
      onError: (e, handler) {
        if (e.response?.statusCode == 401) {
          _onUnauthorized?.call();
        }
        handler.next(e);
      },
    ));
  }

  void setToken(String token) {
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  Future<Map<String, dynamic>> register(String username, String password) async {
    final res = await _dio.post('/api/auth/register', data: {
      'username': username,
      'password': password,
    });
    return res.data;
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final res = await _dio.post('/api/auth/login', data: {
      'username': username,
      'password': password,
    });
    return res.data;
  }

  Future<List<dynamic>> getAgents() async {
    final res = await _dio.get('/api/agents');
    return res.data;
  }

  Future<Map<String, dynamic>> createAgent(String name) async {
    final res = await _dio.post('/api/agents', data: {'name': name});
    return res.data;
  }

  Future<Map<String, dynamic>> updateAgent(
    String id, {
    String? name,
    String? avatarUrl,
    String? bio,
  }) async {
    final data = <String, dynamic>{};
    if (name != null) data['name'] = name;
    if (avatarUrl != null) data['avatar_url'] = avatarUrl;
    if (bio != null) data['bio'] = bio;
    final res = await _dio.put('/api/agents/$id', data: data);
    return res.data;
  }

  Future<void> deleteAgent(String id) async {
    await _dio.delete('/api/agents/$id');
  }

  /// 扫码配对：app 扫码后调用，拉取当前 user 名下 agent 列表。
  /// 返回 PairScanResult（status 非 null 表示票据异常如 expired）。
  Future<PairScanResult> pairScan(String ticketId) async {
    final res = await _dio.post('/api/pair/tickets/$ticketId/scan');
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

  Future<List<dynamic>> getConversations() async {
    final res = await _dio.get('/api/conversations');
    return res.data;
  }

  Future<Map<String, dynamic>> findOrCreateConversation(String agentId) async {
    final res = await _dio.post('/api/conversations', data: {'agent_id': agentId});
    return res.data;
  }

  /// 标记会话已读：unread_count 清零。进入 ChatPage 时调一次。
  Future<Map<String, dynamic>> markConversationRead(String convId) async {
    final res = await _dio.post('/api/conversations/$convId/read');
    return res.data;
  }

  /// 批量按 messageId 标记已读 + server 重算 unread_count。
  /// 用于「用户上滑阅读未读消息时按 messageId 同步进度」。
  /// 返回 `{ok: true, unread_count: N}`，N 是 server 重算后的剩余未读数。
  Future<Map<String, dynamic>> markMessagesRead(
      String convId, List<String> messageIds) async {
    final res = await _dio.post(
      '/api/conversations/$convId/messages/read',
      data: {'message_ids': messageIds},
    );
    return res.data;
  }

  /// 获取会话未读信息（未读数 + 第一条未读消息 id + createdAt）。
  /// 进入 ChatPage 时调用，用于定位未读消息。
  /// 返回原始 JSON，由调用方用 UnreadInfo.fromJson 解析。
  Future<Map<String, dynamic>> getUnreadInfo(String convId) async {
    final res = await _dio.get('/api/conversations/$convId/unread');
    return res.data;
  }

  /// 游标分页拉取历史消息。
  /// [before] 为指定时间戳（RFC3339），返回 created_at < before 的消息。
  /// 不传 before 时返回最新 limit 条。
  Future<List<dynamic>> getMessagesBefore(
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
    return res.data;
  }

  /// 游标分页拉取"未读方向"消息（created_at > after）。
  /// 服务端返回 ASC（最老在前），调用方按需 reverse。
  /// 用于进入会话定位第一条未读：firstUnread + 之后的 N-1 条。
  Future<List<dynamic>> getMessagesAfter(
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
    return res.data;
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

  Future<List<dynamic>> getMessages(String conversationId, {int limit = 50, int offset = 0}) async {
    final res = await _dio.get('/api/conversations/$conversationId/messages',
      queryParameters: {'limit': limit, 'offset': offset});
    return res.data;
  }

  /// 软删单条消息。DELETE /api/messages/:id
  Future<void> deleteMessage(String id) async {
    await _dio.delete('/api/messages/$id');
  }

  /// 批量软删消息。POST /api/messages/batch-delete  body: {"ids":[...]}
  /// 返回服务端实际删除的条数。
  Future<int> batchDeleteMessages(List<String> ids) async {
    final res = await _dio.post(
      '/api/messages/batch-delete',
      data: {'ids': ids},
    );
    return res.data['deleted'] as int;
  }

  Future<String> uploadFile(String filePath) async {
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(filePath),
    });
    final res = await _dio.post('/api/upload', data: formData);
    return res.data['id'];
  }

  /// 上传内存中的图片字节（crop_your_image 裁剪结果是 Uint8List，无磁盘路径）。
  /// fileName 仅用于设置 Content-Disposition，不影响服务端存储。
  Future<String> uploadBytes(Uint8List bytes, {required String fileName}) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: fileName),
    });
    final res = await _dio.post('/api/upload', data: formData);
    return res.data['id'];
  }

  Future<Map<String, dynamic>> getMe() async {
    final res = await _dio.get('/api/users/me');
    return res.data;
  }

  /// 修改当前登录用户的密码。不需要旧密码（JWT 已验证身份）。
  /// 成功返回 {'ok': true}；服务端验证失败（密码太短等）抛 DioException。
  Future<Map<String, dynamic>> changePassword(String newPassword) async {
    final res = await _dio.put('/api/users/me/password', data: {
      'new_password': newPassword,
    });
    return res.data;
  }

  /// 更新当前用户资料（部分更新）。
  /// nickname/bio: null=不传，""=清空。
  /// avatarUrl: null=不传，""=被后端忽略（不清空）。
  /// 返回更新后的完整 user JSON。
  Future<Map<String, dynamic>> updateMe({
    String? nickname,
    String? bio,
    String? avatarUrl,
  }) async {
    final data = <String, dynamic>{};
    if (nickname != null) data['nickname'] = nickname;
    if (bio != null) data['bio'] = bio;
    if (avatarUrl != null) data['avatar_url'] = avatarUrl;
    final res = await _dio.put('/api/users/me', data: data);
    return res.data;
  }

  /// 决策审批。actionId 必须是卡片 actions 列表内的合法 id。
  /// 返回 null 表示成功（HTTP 200），非 null 为错误文案。
  Future<String?> decideApproval(String approvalId, String actionId,
      {String? reason}) async {
    try {
      await _dio.post('/api/approvals/$approvalId/decide', data: {
        'action_id': actionId,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
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
  Future<Map<String, dynamic>?> getApproval(String approvalId) async {
    try {
      final res = await _dio.get('/api/approvals/$approvalId');
      return res.data as Map<String, dynamic>;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }
}
