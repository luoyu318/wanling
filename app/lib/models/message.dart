/// 单条聊天消息。
///
/// N 方 participants 模型下,server 已删除 is_read 字段(下沉到 message_deliveries 表)。
/// 但 client 端仍需"是否已读"本地状态(chat_page 过滤未读消息用),故保留 isRead 字段:
///   - fromJson 不解析(server 不发)
///   - 默认 false(agent 发的消息初始视为未读)
///   - chat_page 滚动看到时本地置 true(配合后台 markMessagesRead API)
///   - user 自己发的消息初始 true(自己发的不算未读)
///
/// isRecalled:撤回状态。收到 scope=recall 的 MESSAGE_DELETE 时,client 把消息
/// 切到 recalled 态而非移除,UI 显示「你/对方撤回了一条消息」占位。
/// recalledByName 用于群聊场景显示「${name} 撤回了一条消息」,dm 场景 client
/// 用 senderId == currentUserId 判断显示「你」还是「对方」。
///
/// status:发送状态(client-only,server 不持久化)。HTTP /api/messages 路径用:
///   - sending:已插本地乐观消息,等待 server 返 message_id
///   - sent:server 已确认,message_id 已替换为 server 真值
///   - failed:发送失败,气泡外侧重试按钮,用户可手动重发
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

  /// 撤回状态(server MESSAGE_DELETE scope=recall 触发,client 本地切换)。
  /// true 时 UI 渲染占位而非消息气泡。
  final bool isRecalled;

  /// 撤回发起人昵称(群聊场景显示用)。dm 场景 client 用 senderId 判断「你/对方」即可。
  /// 仅 isRecalled=true 时有意义。
  final String? recalledByName;

  final DateTime createdAt;

  /// 发送状态(client-only,server 不持久化)。见类注释。
  final MessageStatus status;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderType,
    required this.senderId,
    required this.content,
    this.senderRole,
    this.isRead = false,
    this.isRecalled = false,
    this.recalledByName,
    required this.createdAt,
    this.status = MessageStatus.sent,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final content = json['content'] as Map<String, dynamic>;
    // 撤回状态从 content.msg_type 推断(server 不发独立 is_recalled 字段):
    // server 端 SanitizeForClient 把撤回消息 content 改写成 {msg_type:recalled},
    // client 重新拉历史时按此识别 → isRecalled=true,保持单一真相源,
    // 所有渲染路径(chat_page._RecalledBubble)统一生效。
    final isRecalled = content['msg_type'] == 'recalled';
    return ChatMessage(
      id: json['id'],
      conversationId: json['conversation_id'],
      senderType: json['sender_type'],
      senderId: json['sender_id'],
      content: content,
      senderRole: json['sender_role'] as String?,
      // server 不再发 is_read 字段;client 默认 false。
      // user 自己发的消息由调用方显式设置 isRead=true。
      isRead: false,
      isRecalled: isRecalled,
      createdAt: DateTime.parse(json['created_at']),
      // server 不发 status 字段;历史/远端消息一律视为 sent。
      status: MessageStatus.sent,
    );
  }

  ChatMessage copyWith({
    String? id,
    String? conversationId,
    String? senderType,
    String? senderId,
    Map<String, dynamic>? content,
    String? senderRole,
    bool? isRead,
    bool? isRecalled,
    String? recalledByName,
    DateTime? createdAt,
    MessageStatus? status,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderType: senderType ?? this.senderType,
      senderId: senderId ?? this.senderId,
      content: content ?? this.content,
      senderRole: senderRole ?? this.senderRole,
      isRead: isRead ?? this.isRead,
      isRecalled: isRecalled ?? this.isRecalled,
      recalledByName: recalledByName ?? this.recalledByName,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
    );
  }
}

/// 消息发送状态(client-only,server 不持久化)。
/// 见 ChatMessage.status 字段注释。
enum MessageStatus { sending, sent, failed }
