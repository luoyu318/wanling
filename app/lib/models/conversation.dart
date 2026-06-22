import 'agent.dart';
import 'msg_type.dart';

/// 会话模型。对应后端 GET /api/conversations 返回的 item。
class Conversation {
  final String id;
  final Agent agent;
  // 后端 NullJSON 在 Valid=false 时输出 null 字面量；此处用 nullable 承载。
  final Map<String, dynamic>? lastMessageContent;
  final DateTime lastMessageAt;
  final DateTime createdAt;
  final int unreadCount;
  final bool isPinned;

  Conversation({
    required this.id,
    required this.agent,
    required this.lastMessageContent,
    required this.lastMessageAt,
    required this.createdAt,
    this.unreadCount = 0,
    this.isPinned = false,
  });

  factory Conversation.fromJson(Map<String, dynamic> json) {
    final agentJson = json['agent'] as Map<String, dynamic>;
    final rawContent = json['last_message_content'];
    // 后端 NullJSON.MarshalJSON 在 Valid=false 时输出字面量 null；
    // 也可能整个字段缺失。两种情况都视为 null。
    Map<String, dynamic>? contentMap;
    if (rawContent == null) {
      contentMap = null;
    } else if (rawContent is Map) {
      contentMap = Map<String, dynamic>.from(rawContent);
    } else {
      // 后端 NullJSON.MarshalJSON 只会输出 null 字面量或 JSON 对象。
      // 任何其他类型都是契约违背，fail fast 而非静默接受。
      throw FormatException(
        'last_message_content 应为 null 或 Map，实际为 ${rawContent.runtimeType}：$rawContent',
      );
    }

    return Conversation(
      id: json['id'] as String,
      agent: Agent.fromJson(agentJson),
      lastMessageContent: contentMap,
      lastMessageAt: DateTime.parse(json['last_message_at'] as String),
      createdAt: DateTime.parse(json['created_at'] as String),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      isPinned: (json['is_pinned'] as bool?) ?? false,
    );
  }

  /// 最后一行消息预览（仅文本）。其他类型给出标签占位。
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
      default:
        return '';
    }
  }

  /// 本地复制(修改某字段)。
  Conversation copyWith({
    String? id,
    Agent? agent,
    Map<String, dynamic>? lastMessageContent,
    DateTime? lastMessageAt,
    DateTime? createdAt,
    int? unreadCount,
    bool? isPinned,
  }) =>
      Conversation(
        id: id ?? this.id,
        agent: agent ?? this.agent,
        lastMessageContent: lastMessageContent ?? this.lastMessageContent,
        lastMessageAt: lastMessageAt ?? this.lastMessageAt,
        createdAt: createdAt ?? this.createdAt,
        unreadCount: unreadCount ?? this.unreadCount,
        isPinned: isPinned ?? this.isPinned,
      );
}
