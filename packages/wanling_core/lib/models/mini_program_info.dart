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

class MiniProgramInfo {
  final String id;
  final String appid;
  final String ownerId;
  final String name;
  final int version;
  final String entry;
  final String icon;
  final List<String> permissions;
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
        navigationBar:
            MiniProgramNavigationBar.fromJson(json['navigation_bar'] as Map<String, dynamic>?),
        status: json['status'] as String,
        sha256: json['sha256'] as String,
        size: json['size'] as int,
        signature: json['signature'] as String?,
      );
}
