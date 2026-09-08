/// 全局审批收件箱队列条目。
///
/// 一条待决策卡对应一个 entry。entryKey 是去重与收敛的唯一键：
/// - 独立消息（permission_card/question_card/card）：entryKey = msgId
/// - 聚合卡内嵌元素：entryKey = 'msgId:elementId'
library;

enum InboxCardKind {
  /// OpenCode/hermes 独立权限审批卡消息（msg_type=permission_card）。
  ocPermission,

  /// OpenCode 独立选择题卡消息（msg_type=question_card）。
  ocQuestion,

  /// approvals 审批卡消息（msg_type=card，hermes command/tool/file/slash_confirm/question）。
  approvalCard,

  /// 聚合卡内嵌 permission_card/question_card 元素。
  aggregateElement,
}

class InboxEntry {
  /// 去重/收敛唯一键（见 library 注释）。
  final String entryKey;

  /// 所属消息 ID（收敛时按 msgId 批量清除）。
  final String msgId;

  /// 所属会话 ID（弹窗来源标注 + 「本会话页不弹」判断）。
  final String convId;

  /// 聚合卡内嵌元素时非空。
  final String? elementId;

  final InboxCardKind kind;

  /// 渲染/提交所需载荷：独立消息为 content['data']，聚合元素为 element['data']。
  final Map<String, dynamic> data;

  const InboxEntry({
    required this.entryKey,
    required this.msgId,
    required this.convId,
    required this.kind,
    required this.data,
    this.elementId,
  });
}
