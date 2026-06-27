import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../utils/image_cache_key.dart';

/// 图片缩略图显示尺寸常量（消息列表 / 气泡 / markdown 内嵌图共用）。
///
/// 主流 IM 紧凑风：宽度固定，高度按真实宽高比等比缩放但钳制上下限，
/// 避免超宽图变扁条 / 超高竖图占满屏。
class ImageThumbSize {
  ImageThumbSize._();

  /// 显示宽度（px）。消息气泡宽度的视觉锚点。
  static const double width = 200;

  /// 高度下限（px）。极宽横图（如全景图）至少占这么高，避免细条。
  static const double minHeight = 120;

  /// 高度上限（px）。长截图 / 高竖图（9:16、长图）压到这个高度，
  /// 避免一条消息占满半屏。约 width × 1.4。
  static const double maxHeight = 280;
}

/// 按宽高比计算缩略图显示尺寸：宽固定 [ImageThumbSize.width]，高按比例
/// clamp 到 [minHeight, maxHeight]。
///
/// aspect = width / height（原图比例）。宽图 aspect 大 → 高度小；
/// 高图 aspect 小 → 高度大但被 maxHeight 钳住。
Size imageThumbDisplaySize(double aspect) {
  final h = (ImageThumbSize.width / aspect)
      .clamp(ImageThumbSize.minHeight, ImageThumbSize.maxHeight)
      .toDouble();
  return Size(ImageThumbSize.width, h);
}

/// 占位色块颜色（亮 / 暗主题）。
///
/// 去掉 loading 转圈后，加载中显示一个低饱和色块（主流 IM 风格）。
/// 色块与图片位置/尺寸一致，图片加载好直接盖上去，大脑感知不到「加载过程」。
Color _placeholderColor(bool isDark) =>
    isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE8E8E8);

/// 图片缩略图组件（消息列表 / 气泡 / markdown 内嵌图共用）。
///
/// 三段式尺寸确定策略（零跳动优先）：
/// 1. **主路径**：[aspect] 已知（server 在 message processor 已补 width/height）→
///    构造即知尺寸，色块占位与图片同尺寸，加载完直接替换，无跳动。
/// 2. **兜底**：[aspect] 为 null（存量消息 / server 补失败）→ 先用固定占位尺寸，
///    图片解码后从 ImageInfo 拿真实比例再 setState 切到真实尺寸。
///    用 [AnimatedSize] 平滑过渡（~200ms），缩略图加载快（实测 7ms）几乎无感。
///
/// 视觉策略（对齐主流 IM）：
/// - placeholder 是色块（非转圈），消除「正在加载」的焦虑信号
/// - fadeInDuration / fadeOutDuration = zero，关闭加载完成淡入，硬切显示
/// - errorWidget 同款色块 + 小图标，加载失败也不突兀
///
/// [fit]：image 消息用 [BoxFit.cover]（裁切成紧凑方块，照片风）；
/// markdown 内嵌图用 [BoxFit.contain]（完整不裁切，保留截图/图表信息）。
class ImageThumb extends StatefulWidget {
  final String fileId;
  final String url;
  final Map<String, String> headers;

  /// 已知宽高比（width/height）。null 时走探测兜底。
  final double? aspect;

  /// 图片填充模式。cover 裁切（image 消息）/ contain 不裁切（markdown 内嵌图）。
  final BoxFit fit;

  /// 是否暗色主题（决定占位色块颜色）。
  final bool isDark;

  const ImageThumb({
    super.key,
    required this.fileId,
    required this.url,
    required this.headers,
    this.aspect,
    this.fit = BoxFit.cover,
    this.isDark = false,
  });

  @override
  State<ImageThumb> createState() => _ImageThumbState();
}

class _ImageThumbState extends State<ImageThumb> {
  /// 探测到的宽高比（兜底路径用）。主路径直接用 widget.aspect，不触发探测。
  double? _detectedAspect;

  @override
  Widget build(BuildContext context) {
    final aspect = widget.aspect ?? _detectedAspect;

    // 主路径 + 兜底命中：已知比例，直接按真实尺寸渲染（零跳动）。
    if (aspect != null && aspect > 0) {
      final size = imageThumbDisplaySize(aspect);
      return _buildImage(size);
    }

    // 兜底未命中：固定占位尺寸，解码后探测真实比例。
    // 用 AnimatedSize 让从占位尺寸到真实尺寸的切换平滑。
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      // topCenter：高度变化时顶部对齐，图从顶部往下展开，贴合 Hero 飞行锚点。
      alignment: Alignment.topCenter,
      child: _buildImage(const Size(ImageThumbSize.width, ImageThumbSize.minHeight)),
    );
  }

  Widget _buildImage(Size size) {
    return SizedBox(
      width: size.width,
      height: size.height,
      child: CachedNetworkImage(
        imageUrl: widget.url,
        httpHeaders: widget.headers,
        // 统一 cacheKey 口径：缩略图场景全用 thumb_$fileId。
        cacheKey: thumbCacheKey(widget.fileId),
        fit: widget.fit,
        // 限制解码尺寸上限，对齐缩略图长边 600（覆盖高 DPR）。
        memCacheWidth: 600,
        // 关闭加载完成后的淡入 / 淡出（默认 500ms / 1000ms），
        // 硬切显示，消除「加载很慢」的视觉错觉。
        fadeInDuration: Duration.zero,
        fadeOutDuration: Duration.zero,
        // 色块占位（非转圈）：加载中显示低饱和色块，图片盖上去大脑无感。
        placeholder: (context, url) => _placeholder(),
        // 加载失败：同款色块 + 小图标，不突兀。
        errorWidget: (context, url, error) => _error(),
        // 图片解码完成回调：兜底路径从解码字节拿真实比例。
        // 主路径（aspect 已知）这里也能命中，但已用 widget.aspect，无副作用。
        imageBuilder: _onImageResolved,
      ),
    );
  }

  // CachedNetworkImage 的 imageBuilder 签名：拿到 ImageProvider。
  // 这里不直接渲染（用默认的 Image），只为兜底路径触发 resolve 探测。
  // 注意：imageBuilder 返回的 widget 会替换默认渲染，所以这里仍返回标准 Image。
  Widget _onImageResolved(BuildContext context, ImageProvider provider) {
    _detectAspect(provider);
    return Image(image: provider, fit: widget.fit);
  }

  /// 从 ImageProvider resolve 拿解码后的尺寸（兜底路径补宽高比）。
  /// 只在还没拿到比例时执行。命中内存缓存则同步返回，否则异步回调后 setState。
  void _detectAspect(ImageProvider provider) {
    if (widget.aspect != null || _detectedAspect != null) return;
    final config = createLocalImageConfiguration(context);
    final stream = provider.resolve(config);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      final img = info.image;
      final w = img.width;
      final h = img.height;
      if (w > 0 && h > 0 && mounted) {
        setState(() => _detectedAspect = w / h);
      }
      stream.removeListener(listener);
    });
    stream.addListener(listener);
  }

  Widget _placeholder() => ColoredBox(
        color: _placeholderColor(widget.isDark),
        child: const SizedBox.expand(),
      );

  Widget _error() => ColoredBox(
        color: _placeholderColor(widget.isDark),
        child: Center(
          child: Icon(
            Icons.broken_image_outlined,
            size: 32,
            color: widget.isDark
                ? const Color(0xFF555555)
                : const Color(0xFFBBBBBB),
          ),
        ),
      );
}
