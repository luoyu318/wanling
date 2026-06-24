import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../widgets/avatar.dart';

/// 通知头像尺寸(方形)。与系统 MessagingStyle 头像显示尺寸匹配。
const _kAvatarSize = 48;

/// 方形圆角半径(与 Avatar 组件的 ClipRRect 视觉一致)。
const _kCornerRadius = 9;

/// 加载通知用头像 bitmap。
///
/// 优先级:
/// 1. [avatarUrl] 非空 → Dio 下载 → 裁方形+圆角 → 写文件缓存 → 返回
/// 2. 下载失败 / [avatarUrl] 空 → 生成首字母色块(复用 [Avatar.colorFor])
///
/// 纯函数,不依赖 Riverpod,可在 bg-service isolate 内直接调用。
/// 返回 PNG 编码的 bytes(方形 + 圆角)。
///
/// [avatarUrl] 相对路径(`/api/files/xxx`)会拼 [baseUrl];完整 URL(http/https 开头)直接用。
/// 下载失败不重试(下次新消息自然重试,避免在通知路径卡住)。
/// 兜底色块不写文件缓存(agent 可能后续设头像,下次重新尝试下载)。
Future<Uint8List> loadAvatarBitmap({
  required String agentId,
  required String name,
  String? avatarUrl,
  required String baseUrl,
  required Map<String, String> httpHeaders,
}) async {
  // 先读文件缓存(仅当有 URL 要下载时才碰 I/O,避免兜底路径依赖 path_provider)
  if (avatarUrl != null && avatarUrl.isNotEmpty) {
    try {
      final cacheFile = await _cachePath(agentId);
      if (await cacheFile.exists()) {
        return cacheFile.readAsBytes();
      }
    } catch (_) {
      // 缓存读取失败,继续走下载流程
    }

    // 下载真实头像
    try {
      final fullUrl = avatarUrl.startsWith('http') ? avatarUrl : '$baseUrl$avatarUrl';
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 3),
        receiveTimeout: const Duration(seconds: 3),
      ));
      final resp = await dio.get<List<int>>(
        fullUrl,
        options: Options(responseType: ResponseType.bytes, headers: httpHeaders),
      );
      if (resp.statusCode == 200 && resp.data != null) {
        final bytes = Uint8List.fromList(resp.data!);
        final rounded = _cropRounded(bytes);
        await _writeCache(agentId, rounded);
        return rounded;
      }
    } catch (_) {
      // 下载失败兜底色块,不重试(下次新消息自然重试)
    }
  }

  // 兜底:首字母色块(与 APP Avatar 一致)
  return _initialColorBlock(name);
}

/// 裁剪为方形 + 圆角,返回 PNG bytes。
Uint8List _cropRounded(Uint8List srcBytes) {
  final src = img.decodeImage(srcBytes);
  if (src == null) {
    // 解码失败,返回原图(让系统自己处理)
    return srcBytes;
  }
  // 先裁正方形(居中)
  final side = src.width < src.height ? src.width : src.height;
  final offsetX = (src.width - side) ~/ 2;
  final offsetY = (src.height - side) ~/ 2;
  final cropped = img.copyCrop(src, x: offsetX, y: offsetY, width: side, height: side);
  // 缩放到目标尺寸
  final sized = img.copyResize(cropped, width: _kAvatarSize, height: _kAvatarSize);
  // 加圆角(透明背景)
  final rounded = _applyRoundedCorners(sized, _kCornerRadius);
  return Uint8List.fromList(img.encodePng(rounded));
}

/// 给方形图加圆角(透明背景)。用 image 包像素 mask 合成(纯 Dart,isolate 可用)。
img.Image _applyRoundedCorners(img.Image square, int radius) {
  final out = img.Image(width: square.width, height: square.height, numChannels: 4);
  for (final pixel in square) {
    final x = pixel.x;
    final y = pixel.y;
    if (_isInsideRoundedRect(x, y, square.width, square.height, radius)) {
      out.setPixelRgba(x, y, pixel.r, pixel.g, pixel.b, pixel.a);
    } else {
      out.setPixelRgba(x, y, 0, 0, 0, 0); // 透明
    }
  }
  return out;
}

/// 判断点是否在圆角矩形内。
bool _isInsideRoundedRect(int x, int y, int w, int h, int r) {
  // 四个角的圆心
  final corners = [
    [r, r],
    [w - r - 1, r],
    [r, h - r - 1],
    [w - r - 1, h - r - 1],
  ];
  for (final c in corners) {
    final dx = (x - c[0]).abs();
    final dy = (y - c[1]).abs();
    // 在角的外切正方形区域且距圆心 > r → 在圆角外
    final inCornerBox = (x < r || x >= w - r) && (y < r || y >= h - r);
    if (inCornerBox && (dx * dx + dy * dy) > r * r) {
      return false;
    }
  }
  return true;
}

/// 生成首字母色块 bitmap(复用 Avatar.colorFor)。
///
/// 注:首字母文字渲染在 isolate 纯 Dart 环境较复杂(需字体 bitmap),
/// 简化方案:色块纯色不画字母。视觉上仍是「该 agent 专属颜色」可辨识,
/// 与 APP Avatar 空头像色块基调一致。若后续需首字母,可在 UI isolate
/// 用 Canvas 渲染后 IPC 传 bytes。
Uint8List _initialColorBlock(String name) {
  final color = Avatar.colorFor(name);
  // Flutter Color 的 .red/.green/.blue 已废弃,改用 .r/.g/.b(0.0-1.0)转 0-255
  final image = img.Image(width: _kAvatarSize, height: _kAvatarSize, numChannels: 4);
  img.fill(image,
      color: img.ColorRgba8(
        (color.r * 255.0).round().clamp(0, 255),
        (color.g * 255.0).round().clamp(0, 255),
        (color.b * 255.0).round().clamp(0, 255),
        255,
      ));
  return Uint8List.fromList(img.encodePng(image));
}

Future<File> _cachePath(String agentId) async {
  final dir = await getApplicationDocumentsDirectory();
  final cacheDir = Directory('${dir.path}/avatar_cache');
  if (!await cacheDir.exists()) {
    await cacheDir.create(recursive: true);
  }
  return File('${cacheDir.path}/$agentId.png');
}

Future<void> _writeCache(String agentId, Uint8List bytes) async {
  try {
    final f = await _cachePath(agentId);
    await f.writeAsBytes(bytes);
  } catch (_) {
    // 缓存写入失败不影响通知(内存态 bitmap 已有),静默
  }
}

// 测试可见的兜底色块生成(便于单测验证颜色一致性)
@visibleForTesting
Uint8List initialColorBlockForTest(String name) => _initialColorBlock(name);
