import 'agent.dart';
import 'msg_type.dart';
import 'participant.dart';
import 'user_summary.dart';

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

  /// 个人维度置顶 / 隐藏时间戳(来自 conversation_participants 表)。
  /// null 表示未置顶 / 未隐藏。
  final DateTime? pinnedAt;
  final DateTime? hiddenAt;

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
    this.pinnedAt,
    this.hiddenAt,
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
      lastMessageAt: DateTime.parse(json['last_message_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      lastMessageSenderId: json['last_message_sender_id'] as String?,
      lastMessageSenderType: json['last_message_sender_type'] as String?,
      pinnedAt: json['pinned_at'] != null
          ? DateTime.parse(json['pinned_at'] as String)
          : null,
      hiddenAt: json['hidden_at'] != null
          ? DateTime.parse(json['hidden_at'] as String)
          : null,
    );
  }

  // === 便利 getter ===

  /// 是否置顶(从 pinnedAt 推导,向后兼容老 isPinned 字段)。
  bool get isPinned => pinnedAt != null;

  /// 是否隐藏(从 hiddenAt 推导)。
  bool get isHidden => hiddenAt != null;

  /// 是否群聊。
  bool get isGroup => type == 'group_user' || type == 'group_mixed';

  /// 是否 1-1 单聊。
  bool get isDM => type == 'dm_user_user' || type == 'dm_user_agent';

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

  /// UI 通用头像 URL（agent 优先，dm_user_user 用 otherUser，其他空串走首字母色块）。
  String get displayAvatarUrl =>
      agent?.avatarUrl ?? otherUser?.avatarUrl ?? '';

  /// 最后一行消息预览(仅文本)。其他类型给出标签占位。
  ///
  /// [currentUserId] 用于 recalled 分支切「你/对方撤回了一条消息」。
  /// server ListForUser / GetLastVisibleMessage 返 last_message_sender_id,
  /// 跟当前 user 对比即可判断是 sender 自己撤回还是对方撤回。
  ///
  /// [isGroup] / [senderDisplayName] 群聊场景预留扩展:群聊显示「xxx 撤回了一条消息」,
  /// 当前 dm 场景不需要传,默认走「你/对方」二选一。
  /// 老兼容:server 不返 sender_id 时 fallback 到无称谓「撤回了一条消息」。
  String lastMessagePreview({
    required String currentUserId,
    bool isGroup = false,
    String? senderDisplayName,
  }) {
    final content = lastMessageContent;
    if (content == null) return '';
    // 撤回消息走固定文案(server SanitizeForClient 把 content 改写成 {msg_type:recalled})。
    // 不依赖 msgType 枚举(recalled 不在 MsgType 枚举内,是独立判断)。
    if (content['msg_type'] == 'recalled') {
      if (isGroup &&
          senderDisplayName != null &&
          senderDisplayName.isNotEmpty) {
        return '$senderDisplayName 撤回了一条消息';
      }
      final senderId = lastMessageSenderId;
      if (senderId == null) return '撤回了一条消息';
      return senderId == currentUserId ? '你撤回了一条消息' : '对方撤回了一条消息';
    }
    final data = content['data'];
    if (data is Map && data['text'] is String) return data['text'] as String;
    final msgType = MsgTypeX.fromString(content['msg_type'] as String?);
    switch (msgType) {
      case MsgType.image:
        return '[图片]';
      case MsgType.file:
        return '[文件]';
      case MsgType.card:
        return '[审批]';
      default:
        return '';
    }
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
    DateTime? createdAt,
    int? unreadCount,
    DateTime? pinnedAt,
    DateTime? hiddenAt,
    bool? isPinned,
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
      createdAt: createdAt ?? this.createdAt,
      unreadCount: unreadCount ?? this.unreadCount,
      pinnedAt: newPinnedAt,
      hiddenAt: hiddenAt ?? this.hiddenAt,
    );
  }
}
