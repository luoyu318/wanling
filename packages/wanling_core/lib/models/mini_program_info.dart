/// 小程序注册条目(GET /api/mini-programs)。两层模型:private=自己可见,published=公共库。
library;

class MiniProgramInfo {
  final String id;
  final String appid;
  final String ownerId;
  final String name;
  final int version;
  final String entry;
  final String icon;
  final List<String> permissions;
  final String status;
  final String sha256;
  final int size;

  const MiniProgramInfo({
    required this.id,
    required this.appid,
    required this.ownerId,
    required this.name,
    required this.version,
    this.entry = 'index.html',
    this.icon = '',
    this.permissions = const [],
    required this.status,
    required this.sha256,
    required this.size,
  });

  factory MiniProgramInfo.fromJson(Map<String, dynamic> json) => MiniProgramInfo(
        id: json['id'] as String,
        appid: json['appid'] as String,
        ownerId: json['owner_id'] as String,
        name: json['name'] as String,
        version: json['version'] as int,
        entry: json['entry'] as String? ?? 'index.html',
        icon: json['icon'] as String? ?? '',
        permissions:
            (json['permissions'] as List?)?.cast<String>() ?? const [],
        status: json['status'] as String,
        sha256: json['sha256'] as String,
        size: json['size'] as int,
      );
}
