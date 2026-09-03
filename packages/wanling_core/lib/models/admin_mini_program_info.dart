/// admin 审核视角的小程序条目(GET /api/admin/mini-programs)。
class AdminMiniProgramInfo {
  final String id;
  final String appid;
  final String ownerUsername;
  final String name;
  final int version;
  final String icon; // 相对 URL(带 ?v=),空串走首字 fallback
  final List<String> permissions;
  final String status; // private / published / disabled
  final int size;

  AdminMiniProgramInfo({
    required this.id,
    required this.appid,
    required this.ownerUsername,
    required this.name,
    required this.version,
    required this.icon,
    required this.permissions,
    required this.status,
    required this.size,
  });

  factory AdminMiniProgramInfo.fromJson(Map<String, dynamic> json) {
    return AdminMiniProgramInfo(
      id: json['id'] as String,
      appid: json['appid'] as String,
      ownerUsername: json['owner_username'] as String? ?? '',
      name: json['name'] as String? ?? '',
      version: json['version'] as int? ?? 0,
      icon: json['icon'] as String? ?? '',
      permissions: (json['permissions'] as List<dynamic>? ?? const [])
          .map((e) => e as String)
          .toList(),
      status: json['status'] as String? ?? 'private',
      size: json['size'] as int? ?? 0,
    );
  }
}
