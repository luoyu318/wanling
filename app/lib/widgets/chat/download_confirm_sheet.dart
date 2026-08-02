import 'package:flutter/material.dart';

import '../../utils/file_format.dart' show formatFileSize;
import '../file_type_icon.dart' show FileTypeIcon;

/// 文件下载确认底部弹窗。
///
/// 展示文件名/大小/类型图标，提供「下载」「取消」两个入口。
/// 由 [FileDownloadController.showDownloadSheet] 调用（showModalBottomSheet 的 builder）。
///
/// 行为约定:
/// - 「下载」onTap: 调 [onConfirm]（本 widget 不管 Navigator.pop，调用方负责）。
/// - 「取消」onTap: 本 widget 内部调 Navigator.pop(context)。
class DownloadConfirmSheet extends StatelessWidget {
  final String filename;
  final String mimeType;
  final int fileSize;
  final VoidCallback onConfirm;

  const DownloadConfirmSheet({
    super.key,
    required this.filename,
    required this.mimeType,
    required this.fileSize,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                FileTypeIcon(mimeType: mimeType, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        filename,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        formatFileSize(fileSize),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF999999),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(
              Icons.download_outlined,
              color: Color(0xFF7C5CE7),
            ),
            title: const Text('下载'),
            onTap: onConfirm,
          ),
          ListTile(
            leading: const Icon(Icons.close, color: Color(0xFF999999)),
            title: const Text('取消'),
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}
