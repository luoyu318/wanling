import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// 统一的相册选择器配置（简体中文 + 品牌绿配色）。
///
/// 项目内有两处调 AssetPicker.pickAssets：
///   1. 上传头像（pickImageBytes）—— 返回图片字节做裁剪
///   2. 聊天页发图（ChatPage._pickAlbum）—— 返回 AssetEntity 做上传
/// 两处配置一致，抽出共享避免重复 + 配置漂移。
///
/// - [textDelegate] 固定简体中文（AssetPickerTextDelegate 基类即简中）。
///   虽 main.dart 已固定 locale=zh，显式传更稳健，避免 locale 解析边界情况退回英文。
/// - [pathNameBuilder] 覆盖「全部相册」名：Android 系统返回的 name 是英文 "Recent"，
///   这里转成「最近项目」，其他相册沿用系统原名。
AssetPickerConfig get defaultAssetPickerConfig => AssetPickerConfig(
      requestType: RequestType.image,
      maxAssets: 1,
      themeColor: const Color(0xFF07C160), // 品牌绿，与 APP 配色一致
      textDelegate: const AssetPickerTextDelegate(),
      pathNameBuilder: (path) {
        if (path.isAll) return '最近项目';
        final n = path.name;
        // 兜底：name 为空或仍是英文 Recent 的也转中文
        if (n.isEmpty || n.toLowerCase() == 'recent') return '最近项目';
        return n;
      },
    );

/// 弹出 IM 风相册选择器，让用户选一张图片，返回原始图片字节。
///
/// 用 wechat_assets_picker（基于 photo_manager 直读相册），
/// 不走 Android ActivityResult，避开 image_picker 在 Android 14+ 上的
/// "Reply already submitted" 崩溃。
///
/// 返回 null 表示用户取消。拿到字节后由调用方跳转裁剪页（crop_your_image）。
Future<Uint8List?> pickImageBytes(BuildContext context) async {
  final List<AssetEntity>? result = await AssetPicker.pickAssets(
    context,
    pickerConfig: defaultAssetPickerConfig,
  );
  if (result == null || result.isEmpty) return null;

  // originBytes 返回图片原始字节（photo_manager 内部处理权限请求）
  final asset = result.first;
  return asset.originBytes;
}
