import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:photo_view/photo_view.dart';

/// 图片全屏查看页。复用 CachedNetworkImageProvider 命中 _ImageBubble 的缓存。
///
/// 行为：单击空白处关闭、双指缩放、双击缩放（PhotoView 默认）。
class FullScreenImagePage extends StatelessWidget {
  final String url;
  final Map<String, String> headers;

  const FullScreenImagePage({
    super.key,
    required this.url,
    required this.headers,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: PhotoView(
          imageProvider: CachedNetworkImageProvider(url, headers: headers),
          backgroundDecoration: const BoxDecoration(color: Colors.black),
          minScale: PhotoViewComputedScale.contained,
          maxScale: PhotoViewComputedScale.covered * 4,
        ),
      ),
    );
  }
}
