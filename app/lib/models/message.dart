class ChatMessage {
  final String id;
  final String conversationId;
  final String senderType;
  final String senderId;
  final Map<String, dynamic> content;
  final DateTime createdAt;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderType,
    required this.senderId,
    required this.content,
    required this.createdAt,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'],
    conversationId: json['conversation_id'],
    senderType: json['sender_type'],
    senderId: json['sender_id'],
    content: json['content'] as Map<String, dynamic>,
    createdAt: DateTime.parse(json['created_at']),
  );

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? senderType,
    String? senderId,
    Map<String, dynamic>? content,
    DateTime? createdAt,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderType: senderType ?? this.senderType,
      senderId: senderId ?? this.senderId,
      content: content ?? this.content,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
