import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/msg_type.dart';
import '../rendering/message_content_renderer.dart';
import 'long_press_detector.dart';

export 'markdown_config.dart' show markdownStyle;

/// 格式化时间戳（参考主流 IM 规则）：
/// - 今天 → HH:mm
/// - 昨天 → 昨天 HH:mm
/// - 今年其他天 → MM-DD HH:mm
/// - 跨年 → YYYY-MM-DD HH:mm
///
/// 跨年判断优先于"昨天"判断（防止跨年的最近一天错误显示"昨天"）。
/// now 参数仅用于测试，正常调用不传。
String formatTimestamp(DateTime t, {DateTime? now}) {
  final local = t.toLocal();
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final msgDay = DateTime(local.year, local.month, local.day);
  final diffDays = today.difference(msgDay).inDays;
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');

  // 跨年优先：即使日历日差 1 天（如 2025-12-31 vs 2026-01-01），也按完整日期显示
  if (local.year != n.year) {
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} $hh:$mm';
  }
  if (diffDays == 0) return '$hh:$mm';
  if (diffDays == 1) return '昨天 $hh:$mm';
  final monthStr = local.month.toString().padLeft(2, '0');
  final dayStr = local.day.toString().padLeft(2, '0');
  return '$monthStr-$dayStr $hh:$mm';
}

/// 消息气泡：纯外壳组件（气泡三角/勾选框/长按透传）。
///
/// **选择逻辑已移除**：选择由 ChatPage 的常驻 SelectableRegion 统一接管
/// （包整个 ListView，利用 SDK 内置长按选词路径，落点选词+拉杆）。本组件只
/// 负责渲染外壳，不持有 SelectableRegion/FocusNode。
///
/// **长按手势**：用 [Listener]（pointer 层）捕获长按，回调 [onLongPressStart]。
/// 不用 GestureDetector（会和 SelectableRegion 内部长按抢 gesture arena）。
/// Listener 不进 arena，与 SelectableRegion 的长按选词并存：前者弹菜单，后者
/// 选词+拉杆，二者同时发生（主流 IM 同款）。
///
/// 多选模式：左侧统一勾选框 + 内容列。
class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final String baseUrl;
  final String token;
  final bool selectionMode; // 是否多选模式
  final bool selected;      // 当前消息是否被勾选

  /// 当前会话的全部消息。透传给 renderer 用于画廊收集会话级图片。
  final List<ChatMessage> conversationMessages;

  /// 点击图片时打开画廊的回调（参数 = 被点击图 fileId）。透传给 renderer。
  final void Function(String fileId)? openGallery;

  /// 非多选模式下，长按触发（带触发位置，供 ChatPage 定位菜单）。
  final void Function(LongPressStartDetails details)? onLongPressStart;

  /// 多选模式下点气泡切换勾选。
  final VoidCallback? onTapSelect;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.baseUrl,
    required this.token,
    this.conversationMessages = const [],
    this.openGallery,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPressStart,
    this.onTapSelect,
  });

  @override
  Widget build(BuildContext context) {
    final msgType =
        MsgTypeX.fromString(message.content['msg_type'] as String?);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rc = MessageRenderContext(
      isMe: isMe,
      baseUrl: baseUrl,
      token: token,
      isDark: isDark,
      conversationMessages: conversationMessages,
      openGallery: openGallery,
    );

    // 由 renderer 渲染纯内容
    final content =
        ContentRendererRegistry.render(msgType, message.content, context, rc);
    // 根据 renderer 声明决定是否包气泡三角
    final bubble = ContentRendererRegistry.shouldWrapInBubble(msgType)
        ? BubbleWithTail(isMe: isMe, child: content)
        : content;

    if (selectionMode) {
      // 多选模式：整个 Row 包 GestureDetector，点 Row 任意位置都切换选中。
      // 移除勾选框独立 GestureDetector（避免双层冲突）。
      // 多选模式下不挂 LongPressDetector（长按菜单仅非多选模式触发，
      // 由 chat_page.dart 控制），新增 onTap 无手势冲突。
      //
      // bubble 外包 AbsorbPointer 吸收内容子树 pointer：图片消息内部的
      // GestureDetector（点击进画廊）会截获外层点击导致点图片气泡无法切换
      // 选中。AbsorbPointer 让 hitTest 终止在外层 GestureDetector。
      // 勾选框不包（保留可点）。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTapSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          child: Row(
            children: [
              _buildCheck(),
              const SizedBox(width: 8),
              Expanded(
                child: AbsorbPointer(
                  child: Row(
                    mainAxisAlignment: isMe
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    children: [Flexible(child: bubble)],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 非多选模式:用 LongPressDetector(pointer 层 Listener)捕获长按,回调弹菜单。
    // Listener 不进 gesture arena,与 SelectableRegion 内部长按选词并存。
    return LongPressDetector(
      onLongPressStart: onLongPressStart,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
        child: Row(
          mainAxisAlignment:
              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            Flexible(child: bubble),
          ],
        ),
      ),
    );
  }

  /// 多选模式勾选框:圆形 22px,未选灰边,选中绿底白勾。
  Widget _buildCheck() {
    if (selected) {
      return Container(
        width: 22,
        height: 22,
        decoration: const BoxDecoration(
          color: Color(0xFF07C160),
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check, size: 16, color: Colors.white),
      );
    }
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: const Color(0xFFBBBBBB), width: 2),
      ),
    );
  }
}

/// 带三角的气泡容器。文本 / Markdown / 文件 消息共用。
/// 三角 top 固定 11px（= 单行文字中心），不随气泡高度变化。
class BubbleWithTail extends StatelessWidget {
  final Widget child;
  final bool isMe;

  const BubbleWithTail({super.key, required this.child, required this.isMe});

  @override
  Widget build(BuildContext context) {
    final color = isMe ? const Color(0xFF95EC69) : Colors.white;
    return Stack(
      clipBehavior: Clip.none, // 让三角溢出到气泡外
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(5),
          ),
          constraints: BoxConstraints(
            // 0.9 屏宽(而非 0.95):留余量给代码块/表格的 padding+边框,
            // 避免 markdown 内容 sub-pixel 溢出气泡右侧。
            maxWidth: MediaQuery.of(context).size.width * 0.9,
          ),
          child: child,
        ),
        Positioned(
          left: isMe ? null : -6,
          right: isMe ? -6 : null,
          top: 11,
          child: CustomPaint(
            size: const Size(6, 10),
            painter: _TrianglePainter(color: color, pointLeft: !isMe),
          ),
        ),
      ],
    );
  }
}

/// 画气泡三角（指向左/右外）。颜色跟气泡一致。
class _TrianglePainter extends CustomPainter {
  final Color color;
  final bool pointLeft; // true: agent，顶点指向左外；false: user，顶点指向右外

  const _TrianglePainter({required this.color, required this.pointLeft});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path();
    if (pointLeft) {
      path.moveTo(0, size.height / 2);
      path.lineTo(size.width, 0);
      path.lineTo(size.width, size.height);
    } else {
      path.moveTo(size.width, size.height / 2);
      path.lineTo(0, 0);
      path.lineTo(0, size.height);
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) =>
      color != old.color || pointLeft != old.pointLeft;
}
