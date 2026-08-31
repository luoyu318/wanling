/// 聚合卡协议 schema 版本(data.schema_ver)。从 1 起,缺失视为 1;
/// 破坏性协议变更时递增。APP 读本地 content 的 schema_ver,
/// > 本版本时不应用增量 op(保持现状防误用),等全量替换兜底。
const int aggregateCardSchemaVer = 1;

/// 消息类型，对应 content JSONB 里的 msg_type 字段。
/// 集中定义便于 IDE 补全、避免拼写错误。
enum MsgType {
  text,
  markdown,
  image,
  file,
  mixed,
  card,
  tuiUser,
  reasoning,
  toolCall,
  toolResult,
  toolError,
  subagent,
  question,
  stepFinish,
  toolCard,
  fileDiff,
  permissionCard,
  permissionReply,
  questionCard,
  questionReply,
  slashEcho,
  compactDivider,
  aggregateCard,
  miniProgramCard,
  unknown;
}

extension MsgTypeX on MsgType {
  String get value => switch (this) {
        MsgType.text => 'text',
        MsgType.markdown => 'markdown',
        MsgType.image => 'image',
        MsgType.file => 'file',
        MsgType.mixed => 'mixed',
        MsgType.card => 'card',
        MsgType.tuiUser => 'tui_user',
        MsgType.reasoning => 'reasoning',
        MsgType.toolCall => 'tool_call',
        MsgType.toolResult => 'tool_result',
        MsgType.toolError => 'tool_error',
        MsgType.subagent => 'subagent',
        MsgType.question => 'question',
        MsgType.stepFinish => 'step_finish',
        MsgType.toolCard => 'tool_card',
        MsgType.fileDiff => 'file_diff',
        MsgType.permissionCard => 'permission_card',
        MsgType.permissionReply => 'permission_reply',
        MsgType.questionCard => 'question_card',
        MsgType.questionReply => 'question_reply',
        MsgType.slashEcho => 'slash_echo',
        MsgType.compactDivider => 'compact_divider',
        MsgType.aggregateCard => 'aggregate_card',
        MsgType.miniProgramCard => 'mini_program_card',
        MsgType.unknown => 'unknown',
      };

  /// 生成消息预览文本(单一真相源,notification body 与 conversation 列表预览共用)。
  ///
  /// 返回值约定:
  /// - 非 null:调用方直接使用
  /// - null:无固定文案,调用方按场景 fallback
  ///   - 通知 body: `[新消息]`(通知不允许空 body)
  ///   - 列表预览: `''`(空串)
  ///
  /// null 的来源分两类:
  /// - silent 类(permissionReply/questionReply/compactDivider):过程态不打扰
  /// - 无固定文案类(unknown/mixed + text 的 data.text 缺失):调用方决定
  ///
  /// 注意:
  /// - text/markdown 截断 50 字符(通知场景需求,列表有 ellipsis 兜底)
  /// - recalled 不在此处理(msg_type='recalled' 不在枚举内),调用方独立判断
  static String? preview(MsgType type, Map<String, dynamic>? data) {
    switch (type) {
      case MsgType.text:
      case MsgType.markdown:
        final text = (data?['text'] as String?) ?? '';
        if (text.isEmpty) return null;
        return text.length > 50 ? text.substring(0, 50) : text;
      case MsgType.image:
        return '[图片]';
      case MsgType.file:
        final filename = (data?['filename'] as String?) ?? '';
        return filename.isEmpty ? '[文件]' : '[文件] $filename';
      case MsgType.fileDiff:
        return '[文件变更]';
      case MsgType.tuiUser:
        final text = (data?['text'] as String?) ?? '';
        return text.isNotEmpty ? '[TUI] $text' : '[TUI]';
      case MsgType.reasoning:
        return '[思考]';
      case MsgType.toolCall:
        return '[工具]';
      case MsgType.toolCard:
        final name = (data?['name'] as String?) ?? '';
        return name.isEmpty ? '[工具]' : '[工具] $name';
      case MsgType.toolResult:
        return '[结果]';
      case MsgType.toolError:
        return '[错误]';
      case MsgType.subagent:
      case MsgType.question:
        return '[提问]';
      case MsgType.stepFinish:
        return '[完成]';
      case MsgType.card:
        return '[审批]';
      case MsgType.permissionCard:
        return '权限审批';
      case MsgType.permissionReply:
        return null;
      case MsgType.questionCard:
        return '选择题';
      case MsgType.questionReply:
        return null;
      case MsgType.slashEcho:
        final text = (data?['text'] as String?) ?? '';
        return text.isNotEmpty ? '[命令] $text' : '[命令]';
      case MsgType.compactDivider:
        return null;
      case MsgType.aggregateCard:
        return _aggregateCardPreview(data);
      case MsgType.miniProgramCard:
        final title = (data?['title'] as String?) ?? '';
        return title.isNotEmpty ? '[小程序] $title' : '[小程序]';
      case MsgType.mixed:
        return null;
      case MsgType.unknown:
        return null;
    }
  }

  /// 聚合卡预览文本:优先用 server set_silent 翻转时写入的 data.preview
  /// (增量广播无 elements,通知/摘要直接读 preview);无则扫描元素——先看
  /// 仍待用户介入的交互元素(permission_card / question_card pending,提示
  /// "需要处理"而非正文),再看最后 markdown 正文,截断 50 字符;再无 →
  /// fallback `[聚合回复]`。与 server aggregatePreviewText 同口径。
  /// 回合结束时聚合卡才计未读 + 推送通知,此时 elements 已含最终正文。
  static String? _aggregateCardPreview(Map<String, dynamic>? data) {
    final preview = data?['preview'] as String?;
    if (preview != null && preview.isNotEmpty) {
      return preview.length > 50 ? preview.substring(0, 50) : preview;
    }
    final elements = data?['elements'];
    if (elements is List) {
      // pending 交互优先于正文;倒序取最新一个(与 server aggregatePreviewText 同口径)
      for (final raw in elements.reversed) {
        if (raw is! Map) continue;
        final type = raw['type'];
        if (type == 'permission_card' && _isPendingInteraction(raw['data'])) {
          return '权限审批';
        }
        if (type == 'question_card' && _isPendingInteraction(raw['data'])) {
          return '选择题';
        }
      }
      for (final raw in elements.reversed) {
        if (raw is! Map) continue;
        if (raw['type'] != 'markdown') continue;
        final text = (raw['data'] as Map?)?['text'] as String? ?? '';
        if (text.isEmpty) continue;
        return text.length > 50 ? text.substring(0, 50) : text;
      }
    }
    return '[聚合回复]';
  }

  /// 聚合卡交互元素是否仍需用户介入:status 缺失或为 "pending" → pending;
  /// 终态(approved/denied/answered/rejected/expired)不算。
  /// 与 server isPendingInteraction 同口径。
  static bool _isPendingInteraction(dynamic data) {
    if (data is! Map) return true;
    final status = data['status'];
    if (status is! String) return true;
    return status.isEmpty || status == 'pending';
  }

  static MsgType fromString(String? raw) {
    switch (raw) {
      case 'text':
        return MsgType.text;
      case 'markdown':
        return MsgType.markdown;
      case 'image':
        return MsgType.image;
      case 'file':
        return MsgType.file;
      case 'mixed':
        return MsgType.mixed;
      case 'card':
        return MsgType.card;
      case 'tui_user':
        return MsgType.tuiUser;
      case 'reasoning':
        return MsgType.reasoning;
      case 'tool_call':
        return MsgType.toolCall;
      case 'tool_result':
        return MsgType.toolResult;
      case 'tool_error':
        return MsgType.toolError;
      case 'subagent':
        return MsgType.subagent;
      case 'question':
        return MsgType.question;
      case 'step_finish':
        return MsgType.stepFinish;
      case 'tool_card':
        return MsgType.toolCard;
      case 'file_diff':
        return MsgType.fileDiff;
      case 'permission_card':
        return MsgType.permissionCard;
      case 'permission_reply':
        return MsgType.permissionReply;
      case 'question_card':
        return MsgType.questionCard;
      case 'question_reply':
        return MsgType.questionReply;
      case 'slash_echo':
        return MsgType.slashEcho;
      case 'compact_divider':
        return MsgType.compactDivider;
      case 'aggregate_card':
        return MsgType.aggregateCard;
      case 'mini_program_card':
        return MsgType.miniProgramCard;
      default:
        return MsgType.unknown;
    }
  }
}
