import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

/// 头像裁剪页：用 crop_your_image（纯 Dart）做 1:1 方形裁剪。
///
/// 入参 [rawBytes] 是选图后的原始图片字节。
/// 用户拖拽/缩放调整裁剪框后点「完成」，返回裁剪后的 [Uint8List]（PNG）。
/// 取消或返回上一页则返回 null。
///
/// 为什么不用 image_cropper（UCrop）：UCrop 在 Android 14+ 上用老式
/// startActivityForResult，onActivityResult 被投递两次导致
/// "Reply already submitted" 崩溃。crop_your_image 纯 Flutter widget 渲染，
/// 不碰原生 Activity 生命周期，全平台稳定。
class CropAvatarPage extends StatefulWidget {
  final Uint8List rawBytes;
  const CropAvatarPage({super.key, required this.rawBytes});

  @override
  State<CropAvatarPage> createState() => _CropAvatarPageState();
}

class _CropAvatarPageState extends State<CropAvatarPage> {
  final _cropController = CropController();

  /// 裁剪回调：处理 CropResult（sealed class），成功返回字节，失败提示。
  void _onCropped(CropResult result) {
    switch (result) {
      case CropSuccess(:final croppedImage):
        if (mounted) Navigator.pop(context, croppedImage);
      case CropFailure(:final cause):
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('裁剪失败: $cause')),
          );
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('裁剪头像'),
        actions: [
          TextButton(
            onPressed: () => _cropController.crop(),
            child: const Text('完成',
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ],
      ),
      body: Crop(
        image: widget.rawBytes,
        controller: _cropController,
        aspectRatio: 1, // 锁 1:1 方形
        withCircleUi: false, // 方形裁剪框（显示时 Avatar widget 再做圆角）
        baseColor: Colors.black,
        maskColor: Colors.black.withValues(alpha: 0.6),
        onCropped: _onCropped,
        cornerDotBuilder: (size, edgeAlignment) => const SizedBox.shrink(),
      ),
    );
  }
}
