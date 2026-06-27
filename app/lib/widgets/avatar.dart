import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import '../providers/settings_provider.dart';
import 'unread_badge.dart';

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

    // 相对路径拼 baseUrl；完整 URL（含 host）直接用
    final baseUrl = ref.watch(settingsProvider);
    final effectiveUrl = (url != null && url!.isNotEmpty && !url!.startsWith('http'))
        ? '$baseUrl$url'
        : url;

    // /api/files/:id 走 fileAuth 中间件需要 JWT，
    // CachedNetworkImage 不走 dio，需要手动注入 Authorization header
    final token = ref.watch(authProvider.select((s) => s.token));
    final headers = token != null ? {'Authorization': 'Bearer $token'} : <String, String>{};

    final avatar = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: size,
        height: size,
        child: effectiveUrl != null && effectiveUrl.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: effectiveUrl,
                httpHeaders: headers,
                // cacheKey 命名空间隔离：avatar_ 前缀避免与消息图片 key 冲突。
                // url 含 baseUrl/host，切服务器/账号时磁盘缓存按 url 粒度失效
                // （属合理低频行为）；同一进程内 baseUrl 不变则内存缓存稳定命中。
                cacheKey: 'avatar_$effectiveUrl',
                fit: BoxFit.cover,
                // 限制解码进内存缓存的尺寸上限，按显示尺寸的 3 倍（覆盖高 DPR 屏幕）。
                // 不限制的话图片按原图解码，大图 bitmap 占内存高，几十张就逼近
                // Flutter 默认 ImageCache 上限(100MB) 被 LRU 淘汰；二级页面返回时
                // widget 重建，被淘汰的头像需从磁盘重新解码，那几帧会先显示字母色块
                // placeholder，表现为「色块→图片」的闪烁。限制后内存占用大幅降低，
                // 头像稳定驻留内存，返回时同步命中，不闪。
                memCacheWidth: (size * 3).toInt(),
                // 关闭加载完成后的淡入动画（默认 fadeIn 500ms / fadeOut 1000ms）。
                fadeInDuration: Duration.zero,
                fadeOutDuration: Duration.zero,
                // 加载中 / 加载失败都回退字母色块，避免闪空白
                placeholder: (_, _) => _letterTile(letter, bg),
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
        Positioned(
          top: -4,
          right: -4,
          child: UnreadBadge(count: unreadCount),
        ),
      ],
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
