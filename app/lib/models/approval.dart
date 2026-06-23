import 'package:flutter/material.dart';

/// 审批卡片类型
enum CardType { command, tool, file, unknown }

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
  });

  factory ApprovalCard.fromJson(Map<String, dynamic> j) {
    final rawType = j['card_type'] ?? '';
    final rawState = j['state'] ?? '';
    return ApprovalCard(
      approvalId: j['approval_id'] ?? '',
      cardType: CardType.values.firstWhere(
        (e) => e.name == rawType,
        orElse: () => CardType.unknown,
      ),
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
