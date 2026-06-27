import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

import '../utils/image_normalizer.dart';
import '../utils/snackbar.dart';

/// 头像裁剪页：用 crop_your_image（纯 Dart）做 1:1 方形裁剪。
///
/// 入参 [rawBytes] 是相册选取的原始图片字节（可能为 HEIC 等任意格式）。
/// 页面打开后在 [initState] 内用 [normalizeImageForCrop] 把它转成
/// crop_your_image 能稳定解码的标准 JPEG（规避 image 包无 HEIC 解码器的黑屏），
/// 转码期间显示 loading，转码失败显示错误态可返回重选。
/// 用户拖拽/缩放调整裁剪框后点「完成」，返回裁剪后的 [Uint8List]（PNG）。
/// 取消或返回上一页则返回 null。
///
/// 为何转码放在裁剪页内而非选图后：选图关闭相册页即立即 push 裁剪页，
/// 转码耗时吸收进裁剪页加载态，避免「选图后卡在上一页等转码」的真空期。
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

/// 裁剪页加载状态。
enum _CropLoadState { loading, ready, failed }

class _CropAvatarPageState extends State<CropAvatarPage> {
  final _cropController = CropController();

  /// 当前加载态：loading 转码中 / ready 可裁剪 / failed 转码失败。
  _CropLoadState _state = _CropLoadState.loading;

  /// 转码后的标准 JPEG 字节，ready 态下喂给 Crop widget。
  Uint8List? _normalizedBytes;

  /// 是否正在裁剪中（点「完成」后）。用于禁用按钮 + 蒙层 loading。
  bool _cropping = false;

  @override
  void initState() {
    super.initState();
    _normalize();
  }

  /// 转码原始字节为标准 JPEG。成功转 ready，失败转 failed。
  Future<void> _normalize() async {
    Uint8List bytes;
    try {
      bytes = await normalizeImageForCrop(widget.rawBytes);
    } catch (_) {
      if (mounted) setState(() => _state = _CropLoadState.failed);
      return;
    }
    if (!mounted) return;
    setState(() {
      _normalizedBytes = bytes;
      _state = _CropLoadState.ready;
    });
  }

  /// 点「完成」：触发裁剪并进入 loading 态。
  void _onComplete() {
    if (_cropping) return; // 防重复点击
    setState(() => _cropping = true);
    _cropController.crop();
  }

  /// 裁剪回调：处理 CropResult（sealed class），成功返回字节，失败提示。
  void _onCropped(CropResult result) {
    if (!mounted) return;
    switch (result) {
      case CropSuccess(:final croppedImage):
        Navigator.pop(context, croppedImage);
      case CropFailure(:final cause):
        setState(() => _cropping = false); // 失败：退出 loading 允许重试
        showAppSnackBar(context, '裁剪失败: $cause', type: SnackBarType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(),
      body: switch (_state) {
        _CropLoadState.loading => const _LoadingView(),
        _CropLoadState.failed => const _FailedView(),
        _CropLoadState.ready => _buildCropBody(),
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    // 转码中/失败时「完成」禁用
    final canComplete = _state == _CropLoadState.ready && !_cropping;
    return AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: const Text('裁剪头像'),
      actions: [
        TextButton(
          onPressed: canComplete ? _onComplete : null,
          child: _cropping
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : Text('完成',
                  style: TextStyle(
                    color: canComplete ? Colors.white : Colors.white38,
                    fontSize: 16,
                  )),
        ),
      ],
    );
  }

  /// 裁剪主区域 + 裁剪中蒙层。
  Widget _buildCropBody() {
    return Stack(
      children: [
        Crop(
          image: _normalizedBytes!,
          controller: _cropController,
          aspectRatio: 1, // 锁 1:1 方形
          withCircleUi: false, // 方形裁剪框（显示时 Avatar widget 再做圆角）
          baseColor: Colors.black,
          maskColor: Colors.black.withValues(alpha: 0.6),
          onCropped: _onCropped,
          cornerDotBuilder: (size, edgeAlignment) => const SizedBox.shrink(),
        ),
        // 裁剪中蒙层：阻断手势 + 居中 loading，避免用户在裁剪时再动裁剪框
        if (_cropping)
          Positioned.fill(
            child: AbsorbPointer(
              child: Container(
                color: Colors.black.withValues(alpha: 0.4),
                alignment: Alignment.center,
                child: const CircularProgressIndicator(
                    color: Colors.white, strokeWidth: 2),
              ),
            ),
          ),
      ],
    );
  }
}

/// 转码中视图：黑屏 + 居中菊花 + 文案。
class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
          SizedBox(height: 16),
          Text('正在处理图片…',
              style: TextStyle(color: Colors.white70, fontSize: 14)),
        ],
      ),
    );
  }
}

/// 转码失败视图：错误文案 + 返回重选提示。
class _FailedView extends StatelessWidget {
  const _FailedView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined,
                color: Colors.white38, size: 56),
            const SizedBox(height: 16),
            const Text(
              '图片处理失败',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            const Text(
              '该图片格式不支持，请返回重新选择',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.maybePop(context),
              child: const Text('返回',
                  style: TextStyle(color: Colors.white, fontSize: 14)),
            ),
          ],
        ),
      ),
    );
  }
}
