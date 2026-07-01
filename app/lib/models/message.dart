/// 单条聊天消息。
///
/// N 方 participants 模型下,server 已删除 is_read 字段(下沉到 message_deliveries 表)。
/// 但 client 端仍需"是否已读"本地状态(chat_page 过滤未读消息用),故保留 isRead 字段:
///   - fromJson 不解析(server 不发)
///   - 默认 false(agent 发的消息初始视为未读)
///   - chat_page 滚动看到时本地置 true(配合后台 markMessagesRead API)
///   - user 自己发的消息初始 true(自己发的不算未读)
class ChatMessage {
  final String id;
  final String conversationId;
  final String senderType;
  final String senderId;
  final Map<String, dynamic> content;

  /// server MESSAGE_CREATE payload 加的字段(N 方模型:标识 sender 在该会话的 role)。
  /// UI 渲染可用(如群聊显示 owner 标识)。可选,老 server 可能不返。
  final String? senderRole;

  /// client 本地状态(不从 server JSON 解析)。见类注释。
  final bool isRead;

  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderType,
    required this.senderId,
    required this.content,
    this.senderRole,
    this.isRead = false,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        id: json['id'],
        conversationId: json['conversation_id'],
        senderType: json['sender_type'],
        senderId: json['sender_id'],
        content: json['content'] as Map<String, dynamic>,
        senderRole: json['sender_role'] as String?,
        // server 不再发 is_read 字段;client 默认 false。
        // user 自己发的消息由调用方显式设置 isRead=true。
        isRead: false,
        createdAt: DateTime.parse(json['created_at']),
      );

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? senderType,
    String? senderId,
    Map<String, dynamic>? content,
    String? senderRole,
    bool? isRead,
    DateTime? createdAt,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderType: senderType ?? this.senderType,
      senderId: senderId ?? this.senderId,
      content: content ?? this.content,
      senderRole: senderRole ?? this.senderRole,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
