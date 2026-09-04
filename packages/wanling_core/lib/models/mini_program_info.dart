/// 小程序注册条目(GET /api/mini-programs)。两层模型:private=自己可见,published=公共库。
library;

/// manifest.navigation_bar 声明,宿主 AppBar 的形态与外观。
/// style=default(缺省)原生 AppBar;custom 宿主隐藏 AppBar 全屏。
class MiniProgramNavigationBar {
  final String style;
  final String? backgroundColor;
  final String? foregroundColor;

  const MiniProgramNavigationBar({
    this.style = 'default',
    this.backgroundColor,
    this.foregroundColor,
  });

  bool get isCustom => style == 'custom';

  static MiniProgramNavigationBar? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    return MiniProgramNavigationBar(
      style: json['style'] as String? ?? 'default',
      backgroundColor: json['backgroundColor'] as String?,
      foregroundColor: json['foregroundColor'] as String?,
    );
  }
}

/// manifest.collections 声明的云数据档位。
/// mode: private(owner 独占读写) / shared_write(会话内共享读写)。
class MpCollection {
  final String name;
  final String mode;

  const MpCollection({required this.name, required this.mode});

  static MpCollection fromJson(Map<String, dynamic> json) => MpCollection(
        name: json['name'] as String,
        mode: json['mode'] as String,
      );
}

class MiniProgramInfo {
  final String id;
  final String appid;
  final String ownerId;
  final String name;
  final int version;
  final String entry;
  final String icon;
  final List<String> permissions;
  final List<MpCollection> collections;
  final MiniProgramNavigationBar? navigationBar;
  final String status;
  final String sha256;
  final int size;

  /// 发布包 ed25519 签名(裸签名字节 hex 编码,容器启动前验签用);旧 server 无此字段为 null。
  final String? signature;

  const MiniProgramInfo({
    required this.id,
    required this.appid,
    required this.ownerId,
    required this.name,
    required this.version,
    this.entry = 'index.html',
    this.icon = '',
    this.permissions = const [],
    this.collections = const [],
    this.navigationBar,
    required this.status,
    required this.sha256,
    required this.size,
    this.signature,
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
        collections: (json['collections'] as List?)
                ?.map((e) => MpCollection.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        navigationBar:
            MiniProgramNavigationBar.fromJson(json['navigation_bar'] as Map<String, dynamic>?),
        status: json['status'] as String,
        sha256: json['sha256'] as String,
        size: json['size'] as int,
        signature: json['signature'] as String?,
      );

  /// 列表/底栏 icon 完整 URL;icon 为空返回 ''(调用方走 Avatar 首字 fallback)。
  /// server mpItem.Icon 即相对 URL(?v=版本 快照参数),此处只拼 baseUrl。
  String iconUrlFor(String baseUrl) =>
      icon.isEmpty ? '' : '$baseUrl$icon';
}
