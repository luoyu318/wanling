import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:gal/gal.dart';

import '../models/message.dart';
import '../models/msg_type.dart';

/// 画廊里的一张图片：url + fileId + headers + heroTag。
///
/// fileId 同时作为去重 key 和 Hero tag 来源（fileId 天然唯一）。
class GalleryImage {
  final String url;
  final String fileId;
  final Map<String, String> headers;

  const GalleryImage({
    required this.url,
    required this.fileId,
    required this.headers,
  });

  /// Hero 共享元素 tag：缩略图与画廊当前页用同一个 tag 才能飞行。
  String get heroTag => 'gallery_$fileId';

  /// 由内部 fileId 构造（url 拼 baseUrl/api/files/{id}，headers 带 JWT）。
  ///
  /// baseUrl 末尾的 `/` 会被裁掉，保证拼出的 URL 形态恒为
  /// `{baseUrl}/api/files/{fileId}`。
  ///
  /// 注：这里拼的是**原图** URL（画廊全屏看大图用高清）。消息列表 / 气泡 /
  /// markdown 内嵌图等缩略图场景请用 [thumbUrl]，加载服务端 ?thumb=1 小图。
  factory GalleryImage.fromInternal(
      String fileId, String baseUrl, String token) {
    final b = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return GalleryImage(
      url: '$b/api/files/$fileId',
      fileId: fileId,
      headers: token.isEmpty ? const {} : {'Authorization': 'Bearer $token'},
    );
  }
}

/// 拼缩略图 URL：`{baseUrl}/api/files/{fileId}?thumb=1`。
///
/// 服务端对 ?thumb=1 的处理：有缩略图则返回 600px 长边小图（体积远小于原图，
/// 解码快、内存占用低）；无缩略图（非图片 / 存量数据 / 生成失败）则**自动
/// 降级返回原图**。前端无需感知降级，统一请求 ?thumb=1 即可。
///
/// 用于消息列表 / 气泡 / markdown 内嵌图（显示宽 200，600px 缩略图已覆盖 3×DPR）。
/// 全屏画廊请直接用原图（[GalleryImage.fromInternal]），保证高清。
///
/// baseUrl 末尾的 `/` 会被裁掉，保证 URL 形态恒为
/// `{baseUrl}/api/files/{fileId}?thumb=1`。
String thumbUrl(String baseUrl, String fileId) {
  final b = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  return '$b/api/files/$fileId?thumb=1';
}

/// markdown 图片语法 `![alt](url)` 的正则。非贪婪匹配括号内 url。
final RegExp _markdownImageRe = RegExp(r'!\[[^\]]*\]\(([^)]+)\)');

/// 从 markdown 文本提取内部 server 图片（`/api/files/{id}`）的 fileId 列表。
///
/// 外部 URL 不提取（与 builtin_renderers/_markdownImageBuilder 的安全策略
/// 一致：只放行内部 server 图片，外部 URL 防追踪/SSRF 不进画廊）。
/// 返回顺序与文本出现顺序一致。
List<String> extractInternalImageIds(String? markdownText) {
  if (markdownText == null || markdownText.isEmpty) return const [];
  final result = <String>[];
  for (final m in _markdownImageRe.allMatches(markdownText)) {
    final url = m.group(1) ?? '';
    final id = _extractFileId(url);
    if (id != null) result.add(id);
  }
  return result;
}

/// 从 url 提取 fileId：仅认 `/api/files/{id}` 形态，其余返回 null。
///
/// 兼容 url 带 query（`?token=...`）的情况：取 `?` 前的部分。
String? _extractFileId(String url) {
  const prefix = '/api/files/';
  final idx = url.indexOf(prefix);
  if (idx < 0) return null;
  final tail = url.substring(idx + prefix.length);
  final qIdx = tail.indexOf('?');
  return qIdx >= 0 ? tail.substring(0, qIdx) : tail;
}

/// 遍历会话消息，收集所有图片（image 类型 + markdown 内嵌图），按时间正序
/// 去重（index 0 = 最旧的图）。
///
/// 会话消息列表是 newest first（新→旧，见 chat_provider），收集后需反转，
/// 让画廊 index 0 = 最旧，左滑翻到更新的图（符合「左滑下一张」习惯）。
/// 同一 fileId 跨消息重复只保留首次出现（`seen` 集合去重）。
/// 仅在点击图片时调用一次（懒执行），O(n) 遍历，毫秒级。
List<GalleryImage> collectConversationImages(
  List<ChatMessage> messages,
  String baseUrl,
  String token,
) {
  final seen = <String>{};
  final result = <GalleryImage>[];
  for (final m in messages) {
    final type = MsgTypeX.fromString(m.content['msg_type'] as String?);
    if (type == MsgType.image) {
      final fileId = (m.content['data']?['file_id'] ?? '') as String;
      if (fileId.isNotEmpty && seen.add(fileId)) {
        result.add(GalleryImage.fromInternal(fileId, baseUrl, token));
      }
    } else if (type == MsgType.markdown) {
      final text = m.content['data']?['text'] as String?;
      for (final fileId in extractInternalImageIds(text)) {
        if (seen.add(fileId)) {
          result.add(GalleryImage.fromInternal(fileId, baseUrl, token));
        }
      }
    }
  }
  // 反转：messages 是 newest first，反转后 index 0 = 最旧，符合左滑下一张习惯。
  return result.reversed.toList();
}

/// 保存结果，供 UI 层决定 SnackBar 文案。
enum SaveResult { success, failed }

/// 将画廊图片保存到系统相册。
///
/// 内部图片需 JWT 鉴权（[GalleryImage.headers] 已含 Authorization），gal 自带
/// 下载不带 header，故先用 dio 下载字节，再用 [Gal.putImageBytes] 写入相册
/// （gal 按 magic bytes 自动推断真实格式，无需假设扩展名）。任一步失败即返回
/// [SaveResult.failed]（fail fast，不吞异常但转为业务结果）。
///
/// [dio] 可选注入，便于单测 mock；默认新建独立 Dio 实例（不走 ApiService
/// 拦截器，因 headers 已自带鉴权，无需 401 登出等副作用），设 3 秒超时
/// 防止慢网络下 UI 无反馈（对齐 avatar_bitmap 的超时设置）。
Future<SaveResult> saveToGallery(GalleryImage image, {Dio? dio}) async {
  final client = dio ??
      Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
      ));
  try {
    // 1. 鉴权下载图片字节（headers 已含 Authorization）。
    final resp = await client.get<Uint8List>(
      image.url,
      options: Options(
        headers: image.headers,
        responseType: ResponseType.bytes,
      ),
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
