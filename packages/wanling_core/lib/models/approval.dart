import 'package:flutter/material.dart';

/// 审批卡片类型
enum CardType { command, tool, file, slashConfirm, question, unknown }

/// 审批状态
enum ApprovalState { pending, approved, denied, expired, unknown }

/// 卡片按钮
class ApprovalAction {
  final String id;
  final String label;
  final String icon; // check / shield / x
  final String style; // primary / info / danger

  const ApprovalAction({
    required this.id,
    required this.label,
    required this.icon,
    required this.style,
  });

  factory ApprovalAction.fromJson(Map<String, dynamic> j) => ApprovalAction(
        id: j['id'] ?? '',
        label: j['label'] ?? '',
        icon: j['icon'] ?? '',
        style: j['style'] ?? '',
      );
}

/// 卡片元信息行（📁 工作目录 / ⚠ 风险）
class CardMeta {
  final String icon;
  final String text;
  final bool warn;

  const CardMeta({required this.icon, required this.text, this.warn = false});

  factory CardMeta.fromJson(Map<String, dynamic> j) => CardMeta(
        icon: j['icon'] ?? '',
        text: j['text'] ?? '',
        warn: j['warn'] == true,
      );
}

/// 文件元信息（file 卡片的 file 字段）
class ApprovalFile {
  final String name;
  final int size;
  final String? fileId;

  const ApprovalFile({required this.name, required this.size, this.fileId});

  factory ApprovalFile.fromJson(Map<String, dynamic> j) => ApprovalFile(
        name: j['name'] ?? '',
        size: (j['size'] ?? 0) as int,
        fileId: j['file_id'] as String?,
      );
}

/// question 卡选项（content.data.options 数组项）
class ApprovalOption {
  final String id;
  final String label;

  const ApprovalOption({required this.id, required this.label});

  factory ApprovalOption.fromJson(Map<String, dynamic> j) => ApprovalOption(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? '',
      );
}

/// 卡片消息的 data 字段（content.data）
class ApprovalCard {
  final String approvalId;
  final CardType cardType;
  final String title;
  final String preview;
  final String previewLang;
  final String toolName;
  final ApprovalFile? file;
  final List<CardMeta> meta;
  final List<ApprovalAction> actions;
  final ApprovalState state;
  final String? decidedAction;
  final String? decidedReason;
  final String? decidedBy;
  final DateTime? decidedAt;
  final DateTime expiresAt;
  // question 类型字段：选项列表 + 是否多选 + 决策结果（终态回显）
  final List<ApprovalOption> options;
  final bool multiSelect;
  final List<String> answers;

  const ApprovalCard({
    required this.approvalId,
    required this.cardType,
    required this.title,
    required this.preview,
    required this.previewLang,
    required this.toolName,
    required this.file,
    required this.meta,
    required this.actions,
    required this.state,
    required this.decidedAction,
    required this.decidedReason,
    required this.decidedBy,
    required this.decidedAt,
    required this.expiresAt,
    required this.options,
    required this.multiSelect,
    required this.answers,
  });

  factory ApprovalCard.fromJson(Map<String, dynamic> j) {
    final rawType = j['card_type'] ?? '';
    final rawState = j['state'] ?? '';
    // 后端用 snake_case（command/tool/file/slash_confirm），Dart enum name 是驼峰，
    // 显式映射避免 firstWhere 失配落到 unknown。
    final cardTypeMap = <String, CardType>{
      'command': CardType.command,
      'tool': CardType.tool,
      'file': CardType.file,
      'slash_confirm': CardType.slashConfirm,
      'question': CardType.question,
    };
    return ApprovalCard(
      approvalId: j['approval_id'] ?? '',
      cardType: cardTypeMap[rawType] ?? CardType.unknown,
      title: j['title'] ?? '',
      preview: j['preview'] ?? '',
      previewLang: j['preview_language'] ?? '',
      toolName: j['tool_name'] ?? '',
      file: j['file'] != null ? ApprovalFile.fromJson(j['file']) : null,
      meta: ((j['meta'] ?? []) as List)
          .map((e) => CardMeta.fromJson(e as Map<String, dynamic>))
          .toList(),
      actions: ((j['actions'] ?? []) as List)
          .map((e) => ApprovalAction.fromJson(e as Map<String, dynamic>))
          .toList(),
      state: ApprovalState.values.firstWhere(
        (e) => e.name == rawState,
        orElse: () => ApprovalState.unknown,
      ),
      decidedAction: j['decided_action'] as String?,
      decidedReason: j['decided_reason'] as String?,
      decidedBy: j['decided_by'] as String?,
      decidedAt: j['decided_at'] != null
          ? DateTime.parse(j['decided_at'] as String)
          : null,
      expiresAt: DateTime.parse(j['expires_at'] as String),
      options: ((j['options'] ?? []) as List)
          .map((e) => ApprovalOption.fromJson(e as Map<String, dynamic>))
          .toList(),
      multiSelect: j['multi_select'] as bool? ?? false,
      answers: (j['answers'] as List?)?.cast<String>() ?? const [],
    );
  }

  /// 是否已处于终态（按钮不可点）
  bool get isTerminal =>
      state == ApprovalState.approved ||
      state == ApprovalState.denied ||
      state == ApprovalState.expired;
}

/// 根据 ApprovalState 拿徽章颜色
Color approvalBadgeColor(ApprovalState s) {
  switch (s) {
    case ApprovalState.approved:
      return const Color(0xFF07C160);
    case ApprovalState.denied:
      return const Color(0xFFFA5151);
    case ApprovalState.expired:
      return const Color(0xFF999999);
    default:
      return Colors.transparent;
  }
}

/// 根据 ApprovalState 拿徽章文字
String approvalBadgeText(ApprovalState s) {
  switch (s) {
    case ApprovalState.approved:
      return '✓ 已批准';
    case ApprovalState.denied:
      return '✗ 已拒绝';
    case ApprovalState.expired:
      return '⏰ 已超时';
    default:
      return '';
  }
}

/// 完整审批记录（GET /api/approvals/:id 响应）。
///
/// 与 ApprovalCard 区别：ApprovalCard 是 messages.content.data 镜像（卡片渲染专用），
/// Approval 是完整 server model.Approval 镜像（含 initiator/decider 参与者字段）。
class Approval {
  final String id;
  final String messageId;
  final String conversationId;
  final String initiatorType;
  final String initiatorId;
  final String cardType;
  final String state;
  final List<ApprovalAction> actions;
  final DateTime expiresAt;
  final String sessionKey;
  final DateTime createdAt;
  final String? deciderType;
  final String? deciderId;
  final String? decidedAction;
  final String? decidedBy;
  final String? decidedReason;
  final DateTime? decidedAt;
  final String? allowPattern;
  final String? confirmId;

  Approval({
    required this.id,
    required this.messageId,
    required this.conversationId,
    required this.initiatorType,
    required this.initiatorId,
    required this.cardType,
    required this.state,
    required this.actions,
    required this.expiresAt,
    required this.sessionKey,
    required this.createdAt,
    this.deciderType,
    this.deciderId,
    this.decidedAction,
    this.decidedBy,
    this.decidedReason,
    this.decidedAt,
    this.allowPattern,
    this.confirmId,
  });

  factory Approval.fromJson(Map<String, dynamic> json) {
    return Approval(
      id: json['id'] as String,
      messageId: json['message_id'] as String,
      conversationId: json['conversation_id'] as String,
      initiatorType: json['initiator_type'] as String,
      initiatorId: json['initiator_id'] as String,
      cardType: json['card_type'] as String,
      state: json['state'] as String,
      actions: (json['actions'] as List)
          .map((e) => ApprovalAction.fromJson(e as Map<String, dynamic>))
          .toList(),
      expiresAt: DateTime.parse(json['expires_at'] as String),
      sessionKey: json['session_key'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      deciderType: json['decider_type'] as String?,
      deciderId: json['decider_id'] as String?,
      decidedAction: json['decided_action'] as String?,
      decidedBy: json['decided_by'] as String?,
      decidedReason: json['decided_reason'] as String?,
      decidedAt: json['decided_at'] != null
          ? DateTime.parse(json['decided_at'] as String)
          : null,
      allowPattern: json['allow_pattern'] as String?,
      confirmId: json['confirm_id'] as String?,
    );
  }
}
