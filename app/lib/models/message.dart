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
}
