import 'package:flutter/material.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// 输入条上方待发送图片缩略图条(单图)。
/// 缩略图走 AssetEntityImageProvider(本地相册,无网络);加载失败显示占位。
/// 点 × 删除(onRemove 由调用方清 pendingImageProvider)。
class PendingImageBar extends StatelessWidget {
  final AssetEntity asset;
  final VoidCallback onRemove;

  const PendingImageBar({
    super.key,
    required this.asset,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image(
                image: AssetEntityImageProvider(asset, isOriginal: false),
                width: 64,
                height: 64,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Container(
                  width: 64,
                  height: 64,
                  color: const Color(0xFFEEEEEE),
                  child: const Icon(Icons.image_outlined, size: 20),
                ),
              ),
            ),
            Positioned(
              top: -6,
              right: -6,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                    color: Color(0x99000000),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 12, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
