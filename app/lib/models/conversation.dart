import 'agent.dart';
import 'msg_type.dart';
import 'participant.dart';

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
  /// UI 渲染优先级:title > agent > participants 拼接。
  final AgentSummary? agent;

  /// 会话全部参与者摘要(server BatchLoadParticipantSummaries 返回)。
  final List<Participant> participants;

  final Map<String, dynamic>? lastMessageContent;
  final DateTime lastMessageAt;
  final DateTime createdAt;
  final int unreadCount;

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
    required this.participants,
    required this.lastMessageContent,
    required this.lastMessageAt,
    required this.createdAt,
    this.unreadCount = 0,
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
    final participantsJson = json['participants'] as List? ?? [];

    return Conversation(
      id: json['id'] as String,
      type: json['type'] as String? ?? 'dm_user_agent',
      title: json['title'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      agent: agentJson != null
          ? AgentSummary.fromJson(agentJson as Map<String, dynamic>)
          : null,
      participants: participantsJson
          .map((e) => Participant.fromJson(e as Map<String, dynamic>))
          .toList(),
      lastMessageContent: contentMap,
      lastMessageAt: DateTime.parse(json['last_message_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
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

  /// 最后一行消息预览(仅文本)。其他类型给出标签占位。
  String get lastMessagePreview {
    final content = lastMessageContent;
    if (content == null) return '';
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
    List<Participant>? participants,
    Map<String, dynamic>? lastMessageContent,
    DateTime? lastMessageAt,
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
      participants: participants ?? this.participants,
      lastMessageContent: lastMessageContent ?? this.lastMessageContent,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
      createdAt: createdAt ?? this.createdAt,
      unreadCount: unreadCount ?? this.unreadCount,
      pinnedAt: newPinnedAt,
      hiddenAt: hiddenAt ?? this.hiddenAt,
    );
  }
}
