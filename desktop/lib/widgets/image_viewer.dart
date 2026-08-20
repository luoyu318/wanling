// desktop/lib/widgets/image_viewer.dart
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 滚轮缩放下限。低于 1 允许缩小概览,但不无限小。
const double kImageViewerMinScale = 0.5;

/// 滚轮缩放上限。8x 覆盖截图看细节场景,再大无意义且易迷失。
const double kImageViewerMaxScale = 8.0;

/// 滚轮缩放矩阵计算(纯函数,便于单测)。
///
/// 桌面惯例:delta 负(向上滚)= 放大,正(向下滚)= 缩小。
/// 缩放以 [focal](滚轮光标在 viewport 内的位置)为锚点:光标指向的像素
/// 在缩放前后保持不动,符合桌面看图直觉。
/// 每次滚轮步进按 1.1x(放大)/ 1/1.1(缩小)乘子,连续滚动累积平滑。
Matrix4 wheelZoom(Matrix4 matrix, {required double delta, required Offset focal}) {
  final scale = matrix.getMaxScaleOnAxis();
  final factor = delta < 0 ? 1.1 : 1 / 1.1;
  final target = (scale * factor).clamp(kImageViewerMinScale, kImageViewerMaxScale);
  // 已在边界且继续朝边界外滚:直接原样返回,避免边界抖动。
  if (target == scale) return matrix;
  // 锚点缩放:M' = T(focal) * M * S(target/scale) * T(-focal)。
  // InteractiveViewer 的 matrix 语义:viewport → child 变换,
  // 先平移 focal 到原点、缩放、再平移回去,实现 focal 点不动。
  final effective = target / scale;
  return matrix.clone()
    ..translate(focal.dx, focal.dy)
    ..scale(effective)
    ..translate(-focal.dx, -focal.dy);
}

/// 全屏图片预览 Dialog:黑底 + InteractiveViewer 拖拽平移/捏合缩放 +
/// 滚轮缩放(桌面主路径)+ 关闭按钮/Esc 关闭。
///
/// 与 app 端 Hero 画廊不同,桌面走 Dialog(无路由页转场),原图加载用
/// CachedNetworkImage(带 JWT headers)。 Esc 由 [Focus] 的 onKeyEvent
/// 显式处理,不依赖 ModalBarrier 的平台差异行为。
class ImageViewerDialog extends StatefulWidget {
  final String url;
  final Map<String, String> headers;

  const ImageViewerDialog({
    super.key,
    required this.url,
    this.headers = const {},
  });

  @override
  State<ImageViewerDialog> createState() => ImageViewerState();
}

class ImageViewerState extends State<ImageViewerDialog> {
  /// public:widget 测试直接读 transform 断言缩放。
  final transformationController = TransformationController();

  void _onPointerSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    // 光标位置转 viewport 本地坐标(全屏 Dialog 本地即全局,稳妥仍做转换)。
    final focal = box.globalToLocal(e.position);
    transformationController.value = wheelZoom(
      transformationController.value,
      delta: e.scrollDelta.dy,
      focal: focal,
    );
  }

  @override
  void dispose() {
    transformationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: Colors.black.withValues(alpha: 0.9),
        body: Stack(
          children: [
            Listener(
              onPointerSignal: _onPointerSignal,
              child: InteractiveViewer(
                transformationController: transformationController,
                minScale: kImageViewerMinScale,
                maxScale: kImageViewerMaxScale,
                panEnabled: true,
                scaleEnabled: true,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: widget.url,
                    httpHeaders: widget.headers,
                    fadeInDuration: Duration.zero,
                    placeholder: (_, __) => const SizedBox.expand(),
                    errorWidget: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      size: 48,
                      color: Color(0xFF666666),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: IconButton(
                key: const ValueKey('image_viewer_close'),
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 打开全屏图片预览(入口便捷函数)。
Future<void> showImageViewer(
  BuildContext context, {
  required String url,
  Map<String, String> headers = const {},
}) {
    return showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      // 图片预览允许点黑边关闭(与关闭按钮/Esc 三通道)。
      barrierDismissible: true,
      builder: (_) => ImageViewerDialog(url: url, headers: headers),
    );
}
