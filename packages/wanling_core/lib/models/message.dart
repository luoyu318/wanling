import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/quote.dart';

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

  /// sender 显示名(WS payload + 历史 REST 都返)。
  /// user: nickname || username;agent: name。由 server processor / ListByConversation JOIN 填入。
  /// 群聊渲染昵称用;单聊不渲染(节省视觉空间)。
  final String? senderName;

  /// sender 头像 URL(WS payload + 历史 REST 都返)。
  /// 头像 widget 收到 null/空时走字母色块 fallback。
  final String? senderAvatarUrl;

  /// client 本地状态(不从 server JSON 解析)。见类注释。
  final bool isRead;

  /// 流式占位标记(client-only,server 不持久化)。
  /// 收到 op=14 STREAM 首块时插入 `stream:$streamId` 占位消息(isStreaming=true),
  /// 后续 delta 替换 text 不新增行;终态 MESSAGE_CREATE 带 content.data._stream_id
  /// 时同位置替换占位并清零本字段。_mergeHistory 排除 isStreaming 消息,
  /// 防止 server 历史返回后占位滞留(历史是真相源,只含终态)。
  final bool isStreaming;

  /// 撤回状态(server MESSAGE_DELETE scope=recall 触发,client 本地切换)。
  /// true 时 UI 渲染占位而非消息气泡。
  final bool isRecalled;

  /// 撤回发起人昵称(群聊场景显示用)。dm 场景 client 用 senderId 判断「你/对方」即可。
  /// 仅 isRecalled=true 时有意义。
  final String? recalledByName;

  /// 引用消息元数据(server 富化后嵌入 content.data.quote)。
  /// null 表示该消息未引用任何消息。
  final Quote? quote;

  /// 父消息 id（子 agent 事件才有，主对话流消息为 null）。
  /// server dispatch payload 顶层 `parent_msg_id` + HTTP 列表均透传。
  /// 用于过滤主聊天列表（_filterDisplayable），与 server 端
  /// `WHERE parent_msg_id IS NULL` 行为对齐，避免 local DB 缓存命中时漏过滤。
  final String? parentMsgId;

  /// 根消息 id（多层子 agent 时表示最顶层 task 卡片 id；1 层时 == parentMsgId）。
  /// 子 agent 详情页按此过滤本子树事件。
  final String? rootMsgId;

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
    this.senderName,
    this.senderAvatarUrl,
    this.isRead = false,
    this.isStreaming = false,
    this.isRecalled = false,
    this.recalledByName,
    this.quote,
    this.parentMsgId,
    this.rootMsgId,
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
      senderName: json['sender_name'] as String?,
      senderAvatarUrl: json['sender_avatar_url'] as String?,
      // server 不再发 is_read 字段;client 默认 false。
      // user 自己发的消息由调用方显式设置 isRead=true。
      isRead: false,
      // server 不发 is_streaming 字段;client 默认 false。
      // 占位由 _listenStream 显式置 true,终态替换由 _onMessageCreate 重置为 false。
      isStreaming: false,
      isRecalled: isRecalled,
      // quote 从 content.data.quote 解析;缺失或显式 null 都视为无引用。
      quote: parseQuote(content),
      parentMsgId: json['parent_msg_id'] as String?,
      rootMsgId: json['root_msg_id'] as String?,
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
    String? senderName,
    String? senderAvatarUrl,
    bool? isRead,
    bool? isStreaming,
    bool? isRecalled,
    String? recalledByName,
    Quote? quote,
    String? parentMsgId,
    String? rootMsgId,
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
      senderName: senderName ?? this.senderName,
      senderAvatarUrl: senderAvatarUrl ?? this.senderAvatarUrl,
      isRead: isRead ?? this.isRead,
      isStreaming: isStreaming ?? this.isStreaming,
      isRecalled: isRecalled ?? this.isRecalled,
      recalledByName: recalledByName ?? this.recalledByName,
      quote: quote ?? this.quote,
      parentMsgId: parentMsgId ?? this.parentMsgId,
      rootMsgId: rootMsgId ?? this.rootMsgId,
      createdAt: createdAt ?? this.createdAt,
      status: status ?? this.status,
    );
  }
}

/// 从 content.data.quote 提取 Quote;data 缺失或 quote=null 返 null。
///
/// 顶层公开,供 ChatMessage.fromJson + ChatNotifier._appendOptimisticMessage 复用
/// (乐观消息构造时也需要从 content 抽 quote,否则发送方瞬间气泡上方无引用块)。
Quote? parseQuote(Map<String, dynamic> content) {
  final data = content['data'] as Map<String, dynamic>?;
  if (data == null) return null;
  final raw = data['quote'];
  if (raw == null) return null;
  return Quote.fromJson(raw as Map<String, dynamic>);
}

/// 消息发送状态(client-only,server 不持久化)。
/// 见 ChatMessage.status 字段注释。
enum MessageStatus { sending, sent, failed }

extension ChatMessageX on ChatMessage {
  /// 是否为子 agent 审批卡(parent_msg_id 非空 + permission_card/question_card)。
  /// 不限 status:pending 和终态(approved/denied/expired)都匹配。
  /// 用于扁平聊天流渲染层隐藏 — 所有子审批卡都不在流里单独渲染(pending 贴 task
  /// 卡片下方 ⚡ 缩略条,终态不展示),避免终态卡因时序窗口漏出完整行。
  bool get isChildApprovalCard {
    if (parentMsgId == null || parentMsgId!.isEmpty) return false;
    final mt = MsgTypeX.fromString(content['msg_type'] as String?);
    return mt == MsgType.permissionCard || mt == MsgType.questionCard;
  }

  /// 是否为 pending 子 agent 审批卡(在 isChildApprovalCard 基础上 + status=pending)。
  /// 用于 task 卡片 ⚡ 缩略条聚合 + _filterDisplayable 放行(只放行 pending)。
  bool get isPendingChildApproval =>
      isChildApprovalCard &&
      (content['data'] as Map<String, dynamic>?)?['status'] == 'pending';
}
