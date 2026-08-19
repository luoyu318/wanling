/// 被引用消息的元数据(嵌入 ChatMessage.content.data.quote)。
///
/// 所有字段都是 snapshot,渲染时不再回查被引用消息。
/// 对应 server 端 `internal/model/message.go` 的 `Quote` struct,
/// JSON tag 全部 snake_case,client fromJson 转 camelCase Dart 字段。
class Quote {
  final String messageId; // 被引用消息 ID
  final String senderType; // user / agent
  final String senderId;
  final String senderName; // snapshot,避免每次查库
  final String msgType; // 被引用消息原始类型
  final String preview; // server 抽取的单行预览

  const Quote({
    required this.messageId,
    required this.senderType,
    required this.senderId,
    required this.senderName,
    required this.msgType,
    required this.preview,
  });

  factory Quote.fromJson(Map<String, dynamic> json) {
    return Quote(
      messageId: json['message_id'] as String? ?? '',
      senderType: json['sender_type'] as String? ?? '',
      senderId: json['sender_id'] as String? ?? '',
      senderName: json['sender_name'] as String? ?? '',
      msgType: json['msg_type'] as String? ?? '',
      preview: json['preview'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'message_id': messageId,
        'sender_type': senderType,
        'sender_id': senderId,
        'sender_name': senderName,
        'msg_type': msgType,
        'preview': preview,
      };
}
