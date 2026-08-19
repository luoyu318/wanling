import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/message.dart' show ChatMessage;
import '../../providers/auth_provider.dart' show authProvider;
import '../../providers/settings_provider.dart' show settingsProvider;
import 'package:wanling_core/utils/gallery_image.dart' show collectConversationImages;
import '../../widgets/gallery/zoomable_gallery.dart' show ZoomableGallery;

/// 打开会话级图片画廊。
///
/// 收集会话所有图，定位被点击图索引，透明路由 + Hero 过渡进画廊。
/// 收集结果为空（无任何图片，理论不应发生）则直接返回，不打开空画廊。
void openGallery({
  required BuildContext context,
  required WidgetRef ref,
  required String fileId,
  required List<ChatMessage> messages,
}) {
  final baseUrl = ref.read(settingsProvider);
  final token = ref.read(authProvider).token ?? '';
  final images = collectConversationImages(messages, baseUrl, token);
  if (images.isEmpty) return;
  final index = images.indexWhere((g) => g.fileId == fileId);
  // 用全透明路由：页面本身无入场/退场动画（避免黑色背景横划覆盖 Hero），
  // 只有 Hero 共享元素的飞行过渡可见，背景随 Hero 自然淡入/淡出。
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, _, _) => ZoomableGallery(
        images: images,
        initialIndex: index < 0 ? 0 : index,
      ),
    ),
  );
}
