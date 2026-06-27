import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// 转码后图像的最大边长（像素）。大于此值的原图等比缩小，
/// 既降低裁剪库解码内存，也避免 Image.memory 渲染大图卡顿。
/// 2048 覆盖主流头像清晰度需求（裁剪后仍能输出高质量方形图）。
const _kMaxDimension = 2048.0;

/// 将相册选取的原始图片字节转码为标准 JPEG。
///
/// 解决 crop_your_image 用 image 包（无 HEIC 解码器）导致的黑屏：
/// 这里改用 Flutter 原生解码器（dart:ui，支持 HEIC）解码 + 等比缩放，
/// 再用 image 包 [img.encodeJpg] 重编码为 crop_your_image 能稳定处理的 JPEG。
///
/// 为何解码用 dart:ui 而编码用 image 包：
/// - 解码：image 包无 HEIC 解码器，dart:ui（Skia）支持全格式含 HEIC；
/// - 编码：dart:ui 的 [ui.ImageByteFormat] 无 jpg 常量，image 包有 encodeJpg。
/// 二者通过 RGBA 原始像素桥接（dart:ui toByteData → image fromBytes）。
///
/// Canvas 绘制时铺白底，避免极少数 PNG 透明源转 JPEG 出现黑边。
///
/// 失败抛 [FormatException]，由调用方提示用户重试。
Future<Uint8List> normalizeImageForCrop(Uint8List rawBytes) async {
  // 1. 解码（含 HEIC），拿原始尺寸。dart:ui 解码失败抛通用 Exception
  //    （如 "Invalid image data"），统一转 FormatException 让上层 fail fast 语义清晰。
  ui.Codec codec;
  ui.FrameInfo frame;
  try {
    codec = await ui.instantiateImageCodec(rawBytes);
    frame = await codec.getNextFrame();
  } catch (e) {
    throw FormatException('图片解码失败（可能不是有效图片）: $e');
  }
  final src = frame.image;
  final srcW = src.width;
  final srcH = src.height;

  // 2. 等比缩放：取最长边与 _kMaxDimension 的比例，仅缩小不放大
  final longestSide = srcW > srcH ? srcW.toDouble() : srcH.toDouble();
  final scale =
      longestSide > _kMaxDimension ? _kMaxDimension / longestSide : 1.0;
  final dstW = (srcW * scale).round();
  final dstH = (srcH * scale).round();

  // 3. Canvas 缩放绘制到目标尺寸（铺白底，防透明源转 JPEG 黑边）
  //    canvas 只为绘制副作用，构造后立即级联调用，无需绑定变量。
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawRect(
      ui.Rect.fromLTWH(0, 0, dstW.toDouble(), dstH.toDouble()),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    )
    ..drawImageRect(
      src,
      ui.Rect.fromLTWH(0, 0, srcW.toDouble(), srcH.toDouble()),
      ui.Rect.fromLTWH(0, 0, dstW.toDouble(), dstH.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
  final picture = recorder.endRecording();
  final dst = await picture.toImage(dstW, dstH);

  // 4. 桥接到 image 包编码 JPEG：
  //    dart:ui 无 jpg 格式，取 RGBA 原始像素喂给 image.encodeJpg
  final rgba = await dst.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  src.dispose();
  dst.dispose();
  if (rgba == null) {
    throw FormatException('图片转码失败（无法读取像素）');
  }
  final imageImg = img.Image.fromBytes(
    width: dstW,
    height: dstH,
    bytes: rgba.buffer,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(imageImg, quality: 90));
}
