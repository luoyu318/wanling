import 'agent.dart';
import 'msg_type.dart';
import 'participant.dart';
import 'user_summary.dart';

/// agent_session 元数据（mode/model/git_branch/tokens），由 plugin session.updated 同步到 server，
/// APP 从 conversation API 读取渲染副标题。
/// 注意:cwd(directory)已升级到 conversations.directory 一级列,不在本类中。
class SessionMeta {
  final String mode;
  final String modelId;
  final String providerId;
  final String? variant;
  final String? modelName;
  final String? providerName;
  final String? gitBranch;

  /// 会话累计 token 总数(plugin 上报,可空:旧 session_meta 缺该字段)。
  final int? tokensTotal;

  /// 当前上下文已用 token 数(plugin 上报,可空)。
  final int? contextUsed;

  /// 模型上下文上限(plugin 上报,model 未在缓存时为 0/可空)。
  final int? contextLimit;

  const SessionMeta({
    required this.mode,
    required this.modelId,
    required this.providerId,
    this.variant,
    this.modelName,
    this.providerName,
    this.gitBranch,
    this.tokensTotal,
    this.contextUsed,
    this.contextLimit,
  });

  factory SessionMeta.fromJson(Map<String, dynamic> json) {
    return SessionMeta(
      mode: json['mode'] as String? ?? '',
      modelId: json['model_id'] as String? ?? '',
      providerId: json['provider_id'] as String? ?? '',
      variant: json['variant'] as String?,
      modelName: json['model_name'] as String?,
      providerName: json['provider_name'] as String?,
      gitBranch: (json['git_branch'] as String?)?.isEmpty == true ? null : json['git_branch'] as String?,
      tokensTotal: (json['tokens_total'] as num?)?.toInt(),
      contextUsed: (json['context_used'] as num?)?.toInt(),
      contextLimit: (json['context_limit'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'mode': mode,
        'model_id': modelId,
        'provider_id': providerId,
        if (variant != null) 'variant': variant,
        if (gitBranch != null) 'git_branch': gitBranch,
        if (tokensTotal != null) 'tokens_total': tokensTotal,
        if (contextUsed != null) 'context_used': contextUsed,
        if (contextLimit != null) 'context_limit': contextLimit,
      };
}

/// 会话模型(N 方 participants 通用)。
///
/// server 端 type 字段区分 4 种会话:
///   - dm_user_user:user ↔ user 私聊(必须是好友)
///   - dm_user_agent:user ↔ agent 单聊(老 1-1 模型,向后兼容)
///   - group_user:N 个 user 群聊
///   - group_mixed:user + agent 混合群(本期 agent 端不处理群消息,server 支持)
///
/// title/avatarUrl 仅群聊用,1-1 为 null(对端摘要走 agent 字段或 participants 列表)。
/// pinnedAt/hiddenAt 来自 conversation_participants 表(个人维度)。
class Conversation {
  final String id;
  final String type;
  final String? title;
  final String? avatarUrl;

  /// dm_user_agent 场景填(向后兼容老 APP),其他 type 为 null。
  /// UI 渲染优先级:title > agent > otherUser > participants 拼接。
  final AgentSummary? agent;

  /// dm_user_user 场景填(对方 user 摘要,server ListForUser 返),
  /// 其他 type 为 null。UserSummary 不含 user_id(spec §4.2 防枚举)。
  final UserSummary? otherUser;

  /// 会话全部参与者摘要(server BatchLoadParticipantSummaries 返回)。
  final List<Participant> participants;

  final Map<String, dynamic>? lastMessageContent;
  final DateTime lastMessageAt;
  final DateTime createdAt;
  final int unreadCount;

  /// 最后一条消息的 sender(server ListForUser / GetLastVisibleMessage 返,
  /// 撤回消息也保留原 sender,client 据此切「你/对方撤回」文案)。
  /// null 表示无消息或老 server 不返该字段(fallback 无称谓「撤回了一条消息」)。
  final String? lastMessageSenderId;
  final String? lastMessageSenderType;
  final String? lastMessageSenderName;

  /// 个人维度置顶 / 隐藏时间戳(来自 conversation_participants 表)。
  /// null 表示未置顶 / 未隐藏。
  final DateTime? pinnedAt;
  final DateTime? hiddenAt;

  /// 多 session 开发型 dm 入口行聚合:该 agent 的 agent_session 数量 + 待处理交互卡片数。
  /// 对话型 dm 行为 0(server 端 omitempty 不返)。
  final int sessionCount;
  final int pendingCount;

  /// agent_session 元数据（mode/model/git_branch/tokens），其他 type 为 null。
  final SessionMeta? sessionMeta;

  /// OC session 工作目录(agent_session 创建时固化到 server conversations.directory
  /// 一级列,其他 type 为 null)。EnvMetaStrip 的 cwd 段从这里读,
  /// 不再从 session_meta.cwd 读(已彻底剔除)。
  final String? directory;

  final String? lastAgentReplyContent;

  Conversation({
    required this.id,
    required this.type,
    this.title,
    this.avatarUrl,
    this.agent,
    this.otherUser,
    required this.participants,
    required this.lastMessageContent,
    required this.lastMessageAt,
    required this.createdAt,
    this.unreadCount = 0,
    this.lastMessageSenderId,
    this.lastMessageSenderType,
    this.lastMessageSenderName,
    this.pinnedAt,
    this.hiddenAt,
    this.sessionCount = 0,
    this.pendingCount = 0,
    this.sessionMeta,
    this.directory,
    this.lastAgentReplyContent,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final rawContent = json['last_message_content'];
    Map<String, dynamic>? contentMap;
    if (rawContent == null) {
      contentMap = null;
    } else if (rawContent is Map) {
      contentMap = Map<String, dynamic>.from(rawContent);
    } else {
      throw FormatException(
        'last_message_content 应为 null 或 Map，实际为 ${rawContent.runtimeType}：$rawContent',
      );
    }

    final agentJson = json['agent'];
    final otherUserJson = json['other_user'];
    final participantsJson = json['participants'] as List? ?? [];

    return Conversation(
      id: json['id'] as String,
      type: json['type'] as String? ?? 'dm_user_agent',
      title: json['title'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      agent: agentJson != null
          ? AgentSummary.fromJson(agentJson as Map<String, dynamic>)
          : null,
      otherUser: otherUserJson != null
          ? UserSummary.fromJson(otherUserJson as Map<String, dynamic>)
          : null,
      participants: participantsJson
          .map((e) => Participant.fromJson(e as Map<String, dynamic>))
          .toList(),
      lastMessageContent: contentMap,
      lastMessageAt: json['last_message_at'] != null
          ? DateTime.parse(json['last_message_at'] as String)
          : DateTime.parse(json['created_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      lastMessageSenderId: json['last_message_sender_id'] as String?,
      lastMessageSenderType: json['last_message_sender_type'] as String?,
      lastMessageSenderName: json['last_message_sender_name'] as String?,
      pinnedAt: json['pinned_at'] != null
          ? DateTime.parse(json['pinned_at'] as String)
          : null,
      hiddenAt: json['hidden_at'] != null
          ? DateTime.parse(json['hidden_at'] as String)
          : null,
      sessionCount: (json['session_count'] as num?)?.toInt() ?? 0,
      pendingCount: (json['pending_count'] as num?)?.toInt() ?? 0,
      sessionMeta: json['session_meta'] is Map
          ? SessionMeta.fromJson(json['session_meta'] as Map<String, dynamic>)
          : null,
      directory: (json['directory'] as String?)?.isEmpty == true
          ? null
          : json['directory'] as String?,
      lastAgentReplyContent: json['last_agent_reply_content'] as String?,
    );
  }

  // === 便利 getter ===

  /// 是否置顶(从 pinnedAt 推导,向后兼容老 isPinned 字段)。
  bool get isPinned => pinnedAt != null;

  /// 是否隐藏(从 hiddenAt 推导)。
  bool get isHidden => hiddenAt != null;

  /// 是否群聊。
  /// agent_session(OpenCode 单 session 群)成员固定 1 user + 1 agent,
  /// UI 走群聊样式渲染(头像/标题独立),故纳入 isGroup。
  bool get isGroup =>
      type == 'group_user' || type == 'group_mixed' || type == 'agent_session';

  /// 是否 1-1 单聊。
  bool get isDM => type == 'dm_user_user' || type == 'dm_user_agent';

  /// 是否 user ↔ agent 单聊(老 1-1 模型)。
  /// chat_page 据此跳过头像渲染:agent 头像已在 AppBar 显示,气泡行不重复。
  bool get isUserAgentDM => type == 'dm_user_agent';

  /// 是否 OpenCode agent_session(单 session 群)。
  /// 与 [isUserAgentDM] 区别:agent_session 走群聊样式,dm_user_agent 走 1-1 样式。
  bool get isAgentSession => type == 'agent_session';

  /// UI 通用显示名（按 type 智能分流，避免 NPE）。
  ///
  /// 渲染顺序：
  /// 1. 群聊：title（必填）
  /// 2. dm_user_agent：agent.name（agent 非空）
  /// 3. dm_user_user：从 participants 找对方 user 用 nickname/username
  /// 4. fallback：'私聊'
  ///
  /// 注意：server List 接口不返 participants（仅 conversation_detail 才返），
  /// 故 list 场景下 dm_user_user 会 fallback 到 '私聊'。进入详情页 reload 后
  /// list 通过 WS 事件刷新会拿到 participants。
  String get displayName {
    if (title?.isNotEmpty == true) return title!;
    if (agent != null) return agent!.name;
    if (otherUser != null) return otherUser!.displayName;
    final others = participants.where((p) => p.memberType == 'user');
    if (others.isNotEmpty) return others.first.displayName;
    return '私聊';
  }

  /// UI 通用头像 URL。
  ///
  /// - 群聊:仅用会话头像 [avatarUrl],无则返空串走色块兜底
  ///   (不读 [otherUser] — server 群聊返的 otherUser 是「随机一个其他 participant」,
  ///    每个 user 看到的都不一样,作群头像会乱)
  /// - dm_user_agent:[agent.avatarUrl]
  /// - dm_user_user:[otherUser.avatarUrl]
  /// - 其他:空串走色块
  String get displayAvatarUrl {
    if (isGroup) return avatarUrl ?? '';
    return agent?.avatarUrl ?? otherUser?.avatarUrl ?? '';
  }

  /// 最后一行消息预览(仅文本)。其他类型给出标签占位。
  ///
  /// recalled 分支文案优先级:
  /// 1. senderId == currentUserId →「你撤回了一条消息」(单聊/群聊一致)
  /// 2. isGroup + 有 senderDisplayName →「${name} 撤回了一条消息」
  /// 3. senderId == null → 无称谓「撤回了一条消息」(老 server fallback)
  /// 4. 否则 →「对方撤回了一条消息」
  ///
  /// [currentUserId] 判断是否自己撤回。server ListForUser / GetLastVisibleMessage
  /// 返 last_message_sender_id 用于此对比。
  /// [isGroup] / [senderDisplayName] 群聊非自己撤回时拼「${name} 撤回了一条消息」,
  /// server ListForUser 拉 last_message_sender_name(SQL 子查询补)。
  String lastMessagePreview({
    required String currentUserId,
    bool isGroup = false,
    String? senderDisplayName,
  }) {
    final content = lastMessageContent;
    if (content == null) return '';
    // 撤回消息走固定文案(server SanitizeForClient 把 content 改写成 {msg_type:recalled})。
    // 不依赖 msgType 枚举(recalled 不在 MsgType 枚举内,是独立判断)。
    // 优先级:senderId == currentUserId →「你撤回了一条消息」(单聊/群聊一致);
    // 否则 isGroup + 有 senderDisplayName →「${name} 撤回了一条消息」;
    // 否则 senderId == null → 无称谓「撤回了一条消息」(老 server fallback);
    // 否则 →「对方撤回了一条消息」。
    if (content['msg_type'] == 'recalled') {
      final senderId = lastMessageSenderId;
      if (senderId == currentUserId) return '你撤回了一条消息';
      if (isGroup &&
          senderDisplayName != null &&
          senderDisplayName.isNotEmpty) {
        return '$senderDisplayName 撤回了一条消息';
      }
      if (senderId == null) return '撤回了一条消息';
      return '对方撤回了一条消息';
    }
    final data = content['data'];
    final msgType = MsgTypeX.fromString(content['msg_type'] as String?);
    // 调单一真相源 MsgTypeX.preview。null fallback 空串(列表预览允许空)。
    return MsgTypeX.preview(msgType, data is Map<String, dynamic> ? data : null) ?? '';
  }

  /// 本地复制(修改某字段)。
  ///
  /// 兼容参数 [isPinned]:老代码用 bool isPinned 操作置顶状态,N 方模型下置顶改用 pinnedAt
  /// timestamp。本参数内部转:isPinned=true 设 pinnedAt=now,isPinned=false 设 pinnedAt=null。
  /// 不能与 [pinnedAt] 同时传(歧义)。
  Conversation copyWith({
    String? id,
    String? type,
    String? title,
    String? avatarUrl,
    AgentSummary? agent,
    UserSummary? otherUser,
    List<Participant>? participants,
    Map<String, dynamic>? lastMessageContent,
    DateTime? lastMessageAt,
    String? lastMessageSenderId,
    String? lastMessageSenderType,
    String? lastMessageSenderName,
    DateTime? createdAt,
    int? unreadCount,
    DateTime? pinnedAt,
    DateTime? hiddenAt,
    bool? isPinned,
    int? sessionCount,
    int? pendingCount,
    String? directory,
    String? lastAgentReplyContent,
  }) {
    DateTime? newPinnedAt = pinnedAt ?? this.pinnedAt;
    if (isPinned != null) {
      newPinnedAt = isPinned ? DateTime.now() : null;
    }
    return Conversation(
      id: id ?? this.id,
      type: type ?? this.type,
      title: title ?? this.title,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      agent: agent ?? this.agent,
      otherUser: otherUser ?? this.otherUser,
      participants: participants ?? this.participants,
      lastMessageContent: lastMessageContent ?? this.lastMessageContent,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      lastMessageSenderId: lastMessageSenderId ?? this.lastMessageSenderId,
      lastMessageSenderType: lastMessageSenderType ?? this.lastMessageSenderType,
      lastMessageSenderName: lastMessageSenderName ?? this.lastMessageSenderName,
      createdAt: createdAt ?? this.createdAt,
      unreadCount: unreadCount ?? this.unreadCount,
      pinnedAt: newPinnedAt,
      hiddenAt: hiddenAt ?? this.hiddenAt,
      sessionCount: sessionCount ?? this.sessionCount,
      pendingCount: pendingCount ?? this.pendingCount,
      directory: directory ?? this.directory,
      lastAgentReplyContent: lastAgentReplyContent ?? this.lastAgentReplyContent,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'title': title,
        'avatar_url': avatarUrl,
        'agent': agent?.toJson(),
        'other_user': otherUser?.toJson(),
        'participants': participants.map((p) => p.toJson()).toList(),
        'last_message_content': lastMessageContent,
        'last_message_at': lastMessageAt.toIso8601String(),
        'last_message_sender_id': lastMessageSenderId,
        'last_message_sender_type': lastMessageSenderType,
        'last_message_sender_name': lastMessageSenderName,
        'created_at': createdAt.toIso8601String(),
        'unread_count': unreadCount,
        'pinned_at': pinnedAt?.toIso8601String(),
        'hidden_at': hiddenAt?.toIso8601String(),
      };
}
