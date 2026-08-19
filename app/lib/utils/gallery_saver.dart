// app/lib/utils/gallery_saver.dart
// 相册保存是移动专属能力(gal),留在壳;core 的 gallery_image 仅保留
// 会话图片收集与 URL 生成逻辑。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:gal/gal.dart';

import 'package:wanling_core/utils/gallery_image.dart'
    show GalleryImage, SaveResult;

/// 将画廊图片保存到系统相册。
///
/// 内部图片需 JWT 鉴权（[GalleryImage.headers] 已含 Authorization），gal 自带
/// 下载不带 header，故先用 dio 下载字节，再用 [Gal.putImageBytes] 写入相册
/// （gal 按 magic bytes 自动推断真实格式，无需假设扩展名）。任一步失败即返回
/// [SaveResult.failed]（fail fast，不吞异常但转为业务结果）。
///
/// [onProgress] 可选注入：dio 下载进度回调 `(received, total)`。`total` 为
/// 服务端 Content-Length，未知时为 -1（UI 据此决定显示百分比或不定转圈）。
/// 大图原图可达数 MB，超时放宽到 connect 10s / receive 60s（receive 按两段
/// 数据间隔计，非总时长），避免大图下载超时误报失败。
///
/// [dio] 可选注入，便于单测 mock；默认新建独立 Dio 实例（不走 ApiService
/// 拦截器，因 headers 已自带鉴权，无需 401 登出等副作用）。
Future<SaveResult> saveToGallery(
  GalleryImage image, {
  Dio? dio,
  void Function(int received, int total)? onProgress,
}) async {
  final client = dio ??
      Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 60),
      ));
  try {
    // 1. 鉴权下载图片字节（headers 已含 Authorization）。
    final resp = await client.get<Uint8List>(
      image.url,
      options: Options(
        headers: image.headers,
        responseType: ResponseType.bytes,
      ),
      onReceiveProgress: onProgress,
    );
    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) return SaveResult.failed;

    // 2. gal 写入相册（putImageBytes 按 magic bytes 自动推断格式，免临时文件）。
    //    gal 写入免权限（Android 11+ MediaStore 写入无需申请；Android 6-10 gal
    //    内部会按需申请 WRITE_EXTERNAL_STORAGE，拒绝则抛 GalException 走 failed）。
    await Gal.putImageBytes(bytes, name: image.fileId);
    return SaveResult.success;
  } catch (_) {
    // 下载超时/失败 / GalException 统一转 failed。
    return SaveResult.failed;
  }
}
