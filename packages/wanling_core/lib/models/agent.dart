/// Agent 类型分类(集中 type 字面量 + 维度判断)。
///
/// 两大类(铺垫):
///   - 对话型(Hermes 类): 只看最终文本回复,单会话。
///   - 开发型(OpenCode 类): 多 session + 工具链 + 富 UI 卡片。
///     Claude Code / Codex 等同类后期接入只改 [supportsMultiSession]。
///
/// 存量 agent 的 type 可能为空串(老配对未上报 type),按对话型兼容。
abstract final class AgentCategory {
  static const hermes = 'hermes';
  static const opencode = 'opencode';

  /// 是否多 session(决定一级列表点击路由:走二级列表 vs 直进聊天窗)。
  /// 当前仅 opencode 为 true;Claude Code 等同类加入时在此扩展。
  static bool supportsMultiSession(String type) => type == opencode;
}

/// Agent 在线状态。后端 status 字段是 "online" / "offline" 字符串。
/// 用 enum 集中定义、IDE 友好、避免拼写错误。
enum AgentStatus {
  online,
  offline,
  unknown;
}

extension AgentStatusX on AgentStatus {
  String get value => switch (this) {
        AgentStatus.online => 'online',
        AgentStatus.offline => 'offline',
        AgentStatus.unknown => 'unknown',
      };

  static AgentStatus fromString(String? raw) {
    switch (raw) {
      case 'online':
        return AgentStatus.online;
      case 'offline':
        return AgentStatus.offline;
      default:
        return AgentStatus.unknown;
    }
  }
}

class Agent {
  final String id;
  final String name;
  final String? avatarUrl;
  final String? bio;
  final AgentStatus status;
  final String? secretKey;

  /// Agent 类型标签(参见 [AgentCategory])。
  /// 空串=legacy 对话型;新配对走 hermes/opencode 上报。
  final String type;

  /// 是否多 session 拓扑(server 按 type 注册表注入)。
  /// 决定一级列表点击路由:二级 sessions 页 vs 直进聊天窗。
  /// null=老 server 未下发(本地 fallback type=='opencode')。
  final bool? multiSession;

  Agent({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.bio,
    required this.status,
    this.secretKey,
    this.type = '',
    this.multiSession,
  });

  factory Agent.fromJson(Map<String, dynamic> json) => Agent(
        id: json['id'],
        name: json['name'],
        avatarUrl: json['avatar_url'],
        bio: json['bio'],
        status: AgentStatusX.fromString(json['status']),
        secretKey: json['secret_key'],
        type: json['type'] as String? ?? '',
        multiSession: json['multi_session'] as bool?,
      );

  /// 多 session 路由判定:优先 server 注册表注入值,
  /// null(老 server 缺字段)时 fallback 旧口径 type=='opencode'。
  bool get isMultiSession => multiSession ?? type == AgentCategory.opencode;

  /// copyWith 用 clearBio bool 区分 bio "不动"和"清空"。
  Agent copyWith({
    String? name,
    String? avatarUrl,
    String? bio,
    bool clearBio = false,
    AgentStatus? status,
    String? type,
  }) =>
      Agent(
        id: id,
        name: name ?? this.name,
        avatarUrl: avatarUrl ?? this.avatarUrl,
        bio: clearBio ? null : (bio ?? this.bio),
        status: status ?? this.status,
        secretKey: secretKey,
        type: type ?? this.type,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatar_url': avatarUrl,
        'bio': bio,
        'status': status.value,
        'type': type,
      };
}

/// Agent 摘要(IM 列表 / 会话详情用)。
/// 与 [Agent] 区别:不含 secretKey,只渲染所需的最小字段。
/// bio 仅在需要展示简介的场景(如会话二级页 Drawer 头部)填充,其他可保持 null。
/// N 方 participants 模型下,仅 dm_user_agent 场景会填,其他 type 为 null。
class AgentSummary {
  final String id;
  final String name;
  final String? avatarUrl;
  final AgentStatus status;

  /// Agent 类型标签(参见 [AgentCategory])。
  /// 空串=legacy 对话型;新配对走 hermes/opencode 上报。
  final String type;

  /// 是否多 session 拓扑(server 按 type 注册表注入)。null=老 server 缺字段。
  final bool? multiSession;

  /// Agent 简介(可选)。仅二级页面渲染时透传,API JSON 默认不带。
  final String? bio;

  AgentSummary({
    required this.id,
    required this.name,
    this.avatarUrl,
    required this.status,
    this.type = '',
    this.multiSession,
    this.bio,
  });

  factory AgentSummary.fromJson(Map<String, dynamic> json) => AgentSummary(
        id: json['id'] as String,
        name: json['name'] as String,
        avatarUrl: json['avatar_url'] as String?,
        status: AgentStatusX.fromString(json['status'] as String?),
        type: json['type'] as String? ?? '',
        multiSession: json['multi_session'] as bool?,
        bio: json['bio'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatar_url': avatarUrl,
        'status': status.value,
        'type': type,
        if (multiSession != null) 'multi_session': multiSession,
        if (bio != null) 'bio': bio,
      };

  /// 多 session 路由判定(与 [Agent.isMultiSession] 同口径)。
  bool get isMultiSession => multiSession ?? type == AgentCategory.opencode;
}

/// 可选模型条目(对应 server model.ModelInfo,Task 3 GET /api/agents/:id/models)。
/// 4 字段:provider/model id+name,无 status(模型不区分在线/离线)。
/// fromJson 容错(server 缺字段时回退 '',避免老 server 崩 client)。
class AgentModel {
  final String providerId;
  final String providerName;
  final String modelId;
  final String modelName;

  const AgentModel({
    required this.providerId,
    required this.providerName,
    required this.modelId,
    required this.modelName,
  });

  factory AgentModel.fromJson(Map<String, dynamic> json) {
    return AgentModel(
      providerId: json['provider_id'] as String? ?? '',
      providerName: json['provider_name'] as String? ?? '',
      modelId: json['model_id'] as String? ?? '',
      modelName: json['model_name'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'provider_id': providerId,
        'provider_name': providerName,
        'model_id': modelId,
        'model_name': modelName,
      };
}
