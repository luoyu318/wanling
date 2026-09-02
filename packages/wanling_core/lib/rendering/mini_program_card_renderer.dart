import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/theme/app_colors.dart';
import 'message_content_renderer.dart';

/// 小程序分享卡(大图卡):hero icon + 底部标题栏,独立卡不包气泡。
/// icon 为分享时刻快照(data.icon 相对 URL,?v= 版本参数);缺失/空 → 通用
/// 图标色块 fallback(旧消息兼容)。点击统一交容器页(安装/停用拦截),
/// conv 固定携带,params 非 null 时 URL 编码 JSON 附 launch 透传。
/// renderer 不做安装状态校验(M1 容器页已兜底)。
class MiniProgramCardRenderer implements MessageContentRenderer {
  const MiniProgramCardRenderer();

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'] as Map<String, dynamic>? ?? const {};
    final appid = data['appid'] as String? ?? '';
    final title = data['title'] as String? ?? '小程序';
    final icon = data['icon'] as String? ?? '';

    // 脏数据降级：缺 appid 无法路由，渲染占位文案，不抛异常。
    if (appid.isEmpty) {
      return Text('[小程序卡片]',
          style: TextStyle(
              color:
                  rc.isDark ? const Color(0xFFAAAAAA) : AppColors.textSecondary));
    }

    final params = data['params'];
    var target = '/mini-program/$appid?conv=${rc.convId}';
    if (params != null) {
      target += '&launch=${Uri.encodeComponent(jsonEncode(params))}';
    }

    final iconUrl = icon.isEmpty ? null : '${rc.baseUrl}$icon';
    return InkWell(
      onTap: () => context.push(target),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 200,
        decoration: BoxDecoration(
          color: rc.isDark ? const Color(0xFF26272D) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color:
                  rc.isDark ? const Color(0xFF2E2F36) : const Color(0xFFE8E8E8)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: _MpCardIcon(
                  url: iconUrl,
                  title: title,
                  size: 84,
                  radius: 20,
                  token: rc.token,
                ),
              ),
            ),
            Divider(
              height: 1,
              thickness: 1,
              color:
                  rc.isDark ? const Color(0xFF2E2F36) : const Color(0xFFF2F2F2),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 10),
              child: Row(
                children: [
                  if (iconUrl != null) ...[
                    _MpCardIcon(
                      url: iconUrl,
                      title: title,
                      size: 24,
                      radius: 6,
                      token: rc.token,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: rc.isDark ? const Color(0xFFEEEEEE) : null,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: rc.isDark
                        ? const Color(0xFFAAAAAA)
                        : AppColors.textSecondary,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 卡片 icon:网络图(拼 baseUrl + Bearer headers,cacheKey 独立命名空间);
/// url 空/加载失败 → 通用 widgets 图标色块(accentGreen 12% 底)。
class _MpCardIcon extends StatelessWidget {
  final String? url;
  final String title;
  final double size;
  final double radius;
  final String token;

  const _MpCardIcon({
    required this.url,
    required this.title,
    required this.size,
    required this.radius,
    required this.token,
  });

  @override
  Widget build(BuildContext context) {
    if (url == null) return _fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: url!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        httpHeaders:
            token.isEmpty ? null : {'Authorization': 'Bearer $token'},
        cacheKey: 'mp-card_$url',
        errorWidget: (_, __, ___) => _fallback,
      ),
    );
  }

  Widget get _fallback => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: AppColors.accentGreen.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Icon(
          Icons.widgets_outlined,
          size: size * 0.42,
          color: AppColors.accentGreen,
        ),
      );
}
