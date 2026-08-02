import 'package:flutter/material.dart';
import '../utils/file_format.dart';
import 'file_type_icon.dart';

/// FileCard 的下载状态。
enum DownloadState {
  notDownloaded, // 接收方：未下载
  downloading,   // 接收方：下载中
  downloaded,    // 接收方：已下载
  uploading,     // 发送方：上传中
}

/// 独立文件卡片气泡（不包 BubbleWithTail）。
/// 4 状态机：notDownloaded / downloading / downloaded / uploading。
/// 设计参数：白底，描边按发送方/接收方区分，圆角 16，最小宽度 220。
class FileCard extends StatelessWidget {
  final String fileId;
  final String filename;
  final String mimeType;
  final int fileSize;
  final bool isMe;
  final DownloadState downloadState;
  final double? downloadProgress; // 0.0 - 1.0
  final VoidCallback? onTap;

  const FileCard({
    super.key,
    required this.fileId,
    required this.filename,
    required this.mimeType,
    required this.fileSize,
    required this.isMe,
    required this.downloadState,
    this.downloadProgress,
    this.onTap,
  });

  String _statusText() {
    switch (downloadState) {
      case DownloadState.downloading:
        return '下载中 ${((downloadProgress ?? 0) * 100).toInt()}%';
      case DownloadState.uploading:
        return '上传中 ${((downloadProgress ?? 0) * 100).toInt()}%';
      case DownloadState.downloaded:
        return '已下载 ${formatFileSize(fileSize)}';
      case DownloadState.notDownloaded:
        return formatFileSize(fileSize);
    }
  }

  bool get _showProgress =>
      downloadState == DownloadState.downloading ||
      downloadState == DownloadState.uploading;

  Color _progressColor() {
    if (downloadState == DownloadState.uploading) return const Color(0xFFF59E0B);
    return const Color(0xFF7C5CE7);
  }

  Color _statusColor() {
    if (downloadState == DownloadState.downloaded) return const Color(0xFF22C55E);
    if (_showProgress) return _progressColor();
    return const Color(0xFF999999);
  }

  Widget _actionButton() {
    switch (downloadState) {
      case DownloadState.notDownloaded:
        return GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFF7C5CE7),
              borderRadius: BorderRadius.circular(17),
            ),
            child: const Icon(Icons.arrow_downward, size: 16, color: Colors.white),
          ),
        );
      case DownloadState.downloading:
        // 下载中点击复用 onTap：ChatPage 据当前 _downloadProgress 状态判定走 cancel。
        return GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFFE8E8E8),
              borderRadius: BorderRadius.circular(17),
            ),
            child: const Icon(Icons.close, size: 16, color: Color(0xFF999999)),
          ),
        );
      case DownloadState.downloaded:
        return GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 34, height: 34,
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(17),
            ),
            child: const Icon(Icons.folder_open, size: 16, color: Color(0xFF666666)),
          ),
        );
      case DownloadState.uploading:
        return const SizedBox(width: 34, height: 34);
    }
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = isMe ? const Color(0xFFE0D6F7) : const Color(0xFFE8E8E8);
    final screenWidth = MediaQuery.of(context).size.width;

    return Container(
      constraints: BoxConstraints(
        maxWidth: screenWidth * 0.75,
        minWidth: 220,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x0A000000),
            blurRadius: 3,
            offset: Offset(0, 1),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                FileTypeIcon(mimeType: mimeType),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        filename,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF333333),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _statusText(),
                        style: TextStyle(fontSize: 11, color: _statusColor()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _actionButton(),
              ],
            ),
          ),
          if (_showProgress)
            LinearProgressIndicator(
              value: downloadProgress,
              minHeight: 3,
              backgroundColor: const Color(0xFFE8E8E8),
              valueColor: AlwaysStoppedAnimation<Color>(_progressColor()),
            ),
          if (downloadState == DownloadState.notDownloaded)
            Container(
              padding: const EdgeInsets.only(bottom: 10, top: 2),
              alignment: Alignment.center,
              child: const Text(
                '点击下载 · 下载后可用系统应用打开',
                style: TextStyle(fontSize: 10, color: Color(0xFFAAAAAA)),
              ),
            ),
        ],
      ),
    );
  }
}
