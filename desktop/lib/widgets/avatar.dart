import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_core/utils/gallery_image.dart' show thumbUrl;
import 'unread_badge.dart';

/// 内部图片相对路径前缀（/api/files/），用于识别可走缩略图的头像。
const _internalFilePrefix = '/api/files/';

/// 拼接头像 URL。
///
/// 内部图（/api/files/{id}）走 [thumbUrl] 加 ?thumb=1：头像显示 40px，
/// 服务端 600px 缩略图（几十 KB）远小于原图（用户可能上传 2.5MB 大照片），
/// 加载+解码快，消除闪烁。无缩略图的存量图自动降级原图（见 server Download）。
/// 完整 URL（http 外部图）/ 非标准相对路径保持原拼接逻辑。
String? _resolveAvatarUrl(String baseUrl, String? url) {
  if (url == null || url.isEmpty) return url;
  if (url.startsWith('http')) return url; // 完整 URL 直接用
  if (url.startsWith(_internalFilePrefix)) {
    // 提取 fileId（兼容带 query 的情况）：/api/files/{id} → {id}
    final tail = url.substring(_internalFilePrefix.length);
    final qIdx = tail.indexOf('?');
    final fileId = qIdx >= 0 ? tail.substring(0, qIdx) : tail;
    return thumbUrl(baseUrl, fileId);
  }
  return '$baseUrl$url'; // 非标准相对路径兜底拼 baseUrl
}

/// 头像 widget：首字母 + hash 色板。
/// 若 url 非空优先加载图片，失败 fallback 到字母。
/// 可选 unreadCount：>0 时右上角显示红圆 badge。
///
/// url 支持：
///   - 完整 URL（http/https 开头）：直接用
///   - 相对路径（/api/files/xxx）：拼接当前 settingsProvider 的 baseUrl
/// DB 中存的 avatar_url 通常是相对路径，方便 baseUrl 切换时不变。
class Avatar extends ConsumerWidget {
  final String name;
  final String? url;
  final double size;
  final double radius;
  final int unreadCount;

  const Avatar({
    super.key,
    required this.name,
    this.url,
    this.size = 40,
    this.radius = 6, // 默认方圆角，IM 风
    this.unreadCount = 0,
  });

  // 颜色板（主流 IM 紧凑风配色）
  static const List<Color> palette = [
    Color(0xFF7BB242), // 品牌绿
    Color(0xFF5B8BF7), // 蓝
    Color(0xFFE6A23C), // 橙
    Color(0xFFD94F70), // 粉
    Color(0xFF8B5CF6), // 紫
    Color(0xFF14B8A6), // 青
    Color(0xFF6B7280), // 灰
    Color(0xFFEC4899), // 玫红
  ];

  /// 根据 name 的 hash 选定颜色，同名稳定。
  static Color colorFor(String name) {
    final idx = name.hashCode.abs() % palette.length;
    return palette[idx];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final letter = name.isNotEmpty ? name.characters.first.toUpperCase() : '?';
    final bg = colorFor(name);

    // 头像 URL 拼接策略：
    //   - 内部图（/api/files/xxx 相对路径）→ 走 thumbUrl（?thumb=1 缩略图）。
    //   - 完整 URL（http 开头，外部图）→ 原样用
    //   - 非标准相对路径 → 拼 baseUrl（兼容）
    final baseUrl = ref.watch(settingsProvider);
    final effectiveUrl = _resolveAvatarUrl(baseUrl, url);

    // /api/files/:id 走 fileAuth 中间件需要 JWT，
    // CachedNetworkImage 不走 dio，需要手动注入 Authorization header
    final token = ref.watch(authProvider.select((s) => s.token));
    final headers = token != null
        ? {'Authorization': 'Bearer $token'}
        : <String, String>{};

    final avatar = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: effectiveUrl != null && effectiveUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: effectiveUrl,
                httpHeaders: headers,
                cacheKey: 'avatar_$effectiveUrl',
                fit: BoxFit.cover,
                // 限制解码进内存缓存的尺寸上限，按显示尺寸的 3 倍（覆盖高 DPR 屏幕）。
                memCacheWidth: (size * 3).toInt(),
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                placeholder: (_, _) => _neutralPlaceholder(context),
                errorWidget: (_, _, _) => _letterTile(letter, bg),
              )
            : _letterTile(letter, bg),
      ),
    );

    // 无 badge 直接返回，避免 Stack overhead
    if (unreadCount <= 0) return avatar;

    // Stack：avatar + Positioned 右上 badge。Clip.none 让 badge 溢出头像边缘。
    return Stack(
      clipBehavior: Clip.none,
      children: [
        avatar,
        Positioned(top: -4, right: -4, child: UnreadBadge(count: unreadCount)),
      ],
    );
  }

  /// 加载中占位：中性灰色块（亮 #E8E8E8 / 暗 #2A2A2A）。
  Widget _neutralPlaceholder(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE8E8E8),
      child: const SizedBox.expand(),
    );
  }

  Widget _letterTile(String letter, Color bg) {
    return Container(
      color: bg,
      alignment: Alignment.center,
      child: Text(
        letter,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.45,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
