/// 扫码配对：scan 接口返回的 agent 摘要（不含 secret_key）。
class PairAgentSummary {
  final String id;
  final String name;
  final String? avatarUrl;
  final String? bio;
  final String status; // online/offline

  PairAgentSummary({
    required this.id,
    required this.name,
    this.avatarUrl,
    this.bio,
    required this.status,
  });

  factory PairAgentSummary.fromJson(Map<String, dynamic> json) =>
      PairAgentSummary(
        id: json['id'] as String,
        name: json['name'] as String,
        avatarUrl: json['avatar_url'] as String?,
        bio: json['bio'] as String?,
        status: json['status'] as String? ?? 'offline',
      );
}

/// 扫码配对：scan 接口返回整体。
/// status 仅在票据异常（expired/not_found）时非 null；正常时 agents 为该用户名下 agent 列表。
class PairScanResult {
  final String? status;
  final List<PairAgentSummary> agents;

  PairScanResult({this.status, required this.agents});

  factory PairScanResult.fromJson(Map<String, dynamic> json) {
    final rawList = json['agents'] as List<dynamic>?;
    return PairScanResult(
      status: json['status'] as String?,
      agents: rawList
              ?.map((e) => PairAgentSummary.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }
}

/// 扫码配对：complete 接口返回。
class PairCompleteResult {
  final String agentId;
  final String agentName;

  PairCompleteResult({required this.agentId, required this.agentName});

  factory PairCompleteResult.fromJson(Map<String, dynamic> json) =>
      PairCompleteResult(
        agentId: json['agent_id'] as String,
        agentName: json['agent_name'] as String,
      );
}
