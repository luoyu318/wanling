import 'package:flutter/material.dart';
import 'package:wanling_core/utils/file_format.dart' show formatFileSize, mimeFromExt;
import 'package:wanling_core/widgets/file_type_icon.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

import '../../providers/pending_attachment_provider.dart';

/// 输入条上方待发送附件预览条(单挂载:图片缩略图或文件图标+文件名)。
/// 图片缩略图走 AssetEntityImageProvider(本地相册,无网络);文件显示
/// FileTypeIcon(mime 按扩展名推断配色)+ 文件名/大小。点 × 删除
/// (onRemove 由调用方清 pendingAttachmentProvider)。
class PendingAttachmentBar extends StatelessWidget {
  final PendingAttachment attachment;
  final VoidCallback onRemove;

  const PendingAttachmentBar({
    super.key,
    required this.attachment,
    required this.onRemove,
  });

  String _extOf(String path) {
    final lower = path.toLowerCase();
    final dot = lower.lastIndexOf('.');
    return dot >= 0 ? lower.substring(dot) : '';
  }

  @override
  Widget build(BuildContext context) {
    return switch (attachment) {
      PendingImageAsset(:final asset) => _frame(
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
        ),
      PendingFileAttachment(:final path, :final name, :final size) => _frame(
          Row(
            children: [
              FileTypeIcon(
                mimeType: mimeFromExt(_extOf(path.isNotEmpty ? path : name)),
                size: 44,
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatFileSize(size),
                    style: const TextStyle(fontSize: 11, color: Color(0xFF999999)),
                  ),
                ],
              ),
            ],
          ),
        ),
    };
  }

  /// 统一外壳:内容 + 右上角删除按钮。
  Widget _frame(Widget child) {
    return Row(
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            child,
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
