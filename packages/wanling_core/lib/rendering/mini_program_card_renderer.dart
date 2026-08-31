import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/theme/app_colors.dart';
import 'message_content_renderer.dart';

/// 小程序卡片渲染器（mini_program_card）：icon + 名称 + 打开入口。
///
/// 点击统一交容器页处理（自动安装/停用拦截），携带来源会话 conv 供
/// getChatContext；params 非 null 时以 URL 编码 JSON 附在 launch query 上
/// 透传给小程序（spec §8）。renderer 不做安装状态校验（M1 容器页已兜底）。
class MiniProgramCardRenderer implements MessageContentRenderer {
  const MiniProgramCardRenderer();

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => true;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'] as Map<String, dynamic>? ?? const {};
    final appid = data['appid'] as String? ?? '';
    final title = data['title'] as String? ?? '小程序';

    // 脏数据降级：缺 appid 无法路由，渲染占位文案，不抛异常。
    if (appid.isEmpty) {
      return Text('[小程序卡片]',
          style: TextStyle(color: rc.isDark
              ? const Color(0xFFAAAAAA)
              : AppColors.textSecondary));
    }

    // 跳转 URL：conv 固定携带；params 非 null 时追加 launch（URL 编码 JSON，
    // 容器页转交给 H5 虚拟 origin 入口 query）。
    final params = data['params'];
    var target = '/mini-program/$appid?conv=${rc.convId}';
    if (params != null) {
      target += '&launch=${Uri.encodeComponent(jsonEncode(params))}';
    }

    return InkWell(
      onTap: () => context.push(target),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          // 深色：白卡底 → 26272D，边框 #E8E8E8 → 2E2F36（对齐 _TextPreviewCard 灰阶）
          color: rc.isDark ? const Color(0xFF26272D) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: rc.isDark ? const Color(0xFF2E2F36) : const Color(0xFFE8E8E8)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.widgets_outlined, size: 28, color: AppColors.accentGreen),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      // 深色灰阶反转：#111 → #EEEEEE
                      color: rc.isDark ? const Color(0xFFEEEEEE) : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '小程序 · 点击打开',
                    style: TextStyle(
                      fontSize: 11,
                      // 深色灰阶反转：#999 → #AAAAAA
                      color: rc.isDark
                          ? const Color(0xFFAAAAAA)
                          : AppColors.textSecondary,
                    ),
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
