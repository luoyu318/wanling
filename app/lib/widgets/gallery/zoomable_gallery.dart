import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../utils/gallery_image.dart';
import '../../utils/image_cache_key.dart';
import '../../utils/snackbar.dart';
import '../long_press_detector.dart';
import '../panel_item.dart';
import 'photo_view/photo_view.dart';
import 'photo_view/photo_view_gallery.dart';
import 'photo_view/src/controller/photo_view_controller.dart';
import 'photo_view/src/photo_view_scale_state.dart';

/// 全屏图片画廊：用内化的 [PhotoViewGallery] 统一处理翻页与缩放的手势边界。
///
/// 翻页采用 photo_view 原版的 shouldMove 协调机制：图片未到边时由 PhotoView 平移，
/// 到边后让 PageView 的 drag 赢得手势，从而实时跟随手指翻页（放大态与未放大态体验
/// 一致，到边即带出下一张图）。翻到新页时彻底重置离开页的 position/scaleState，
/// 避免再次进入该页时残留放大位置导致卡死。
///
/// 关键：通过 [PhotoViewScaleStateController] 监听 scaleState（双击和手势缩放
/// 都会更新它），而非 onScaleEnd（双击不触发 onScaleEnd，会导致状态不同步）。
class ZoomableGallery extends StatefulWidget {
  final List<GalleryImage> images;
  final int initialIndex;

  const ZoomableGallery({
    super.key,
    required this.images,
    required this.initialIndex,
  });

  @override
  State<ZoomableGallery> createState() => _ZoomableGalleryState();
}

class _ZoomableGalleryState extends State<ZoomableGallery> {
  late final PageController _pageController;

  /// 每页一个 controller，管该页 position/scale 数值；翻页时重置离开页避免残留。
  late final List<PhotoViewController> _controllers;

  /// 每页一个 scaleStateController，用于监听该页缩放状态。
  late final List<PhotoViewScaleStateController> _scaleStateControllers;

  /// 各页 scaleState 流的订阅（dispose 时取消）。
  final List<StreamSubscription<PhotoViewScaleState>> _subs = [];

  /// 当前显示页索引。
  int _currentIndex = 0;

  /// 当前页是否放大态。
  bool _zoomed = false;

  /// 翻页后待重置的离开页索引。滚动到该页完全消失（|page - index| >= 1.0）时才重置，
  /// 避免图片在半屏可见时被缩回原大小。null 表示无待重置页。
  int? _resetPendingIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.images.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
    // 监听连续滚动位置：离开页完全滑出屏幕外才重置，而非 onPageChanged 的 50%。
    _pageController.addListener(_onPageScroll);
    _controllers =
        List.generate(widget.images.length, (_) => PhotoViewController());
    _scaleStateControllers = List.generate(widget.images.length, (_) {
      final c = PhotoViewScaleStateController();
      // outputScaleStateStream：双击和手势缩放都会更新它，替代 onScaleEnd
      // （双击不触发 onScaleEnd，会导致 _zoomed 状态不同步）。
      _subs.add(c.outputScaleStateStream.listen(_onScaleStateChanged));
      return c;
    });
  }

  @override
  void dispose() {
    _pageController.removeListener(_onPageScroll);
    for (final s in _subs) {
      s.cancel();
    }
    for (final c in _scaleStateControllers) {
      c.dispose();
    }
    for (final c in _controllers) {
      c.dispose();
    }
    _pageController.dispose();
    super.dispose();
  }

  /// scaleState 流事件：按当前页状态更新 _zoomed。
  void _onScaleStateChanged(PhotoViewScaleState state) {
    _updateZoomed(state);
  }

  void _updateZoomed(PhotoViewScaleState state) {
    // initial / originalSize 视为原始态，其余（covering/zoomedIn/zoomedOut）为放大态。
    final zoomed = state != PhotoViewScaleState.initial &&
        state != PhotoViewScaleState.originalSize;
    if (zoomed != _zoomed) {
      setState(() => _zoomed = zoomed);
    }
  }

  /// 关闭画廊（pop 路由）。单击(onTapUp) 调它。public 以便测试覆盖关闭逻辑。
  void close() => Navigator.of(context).pop();

  /// 滚动位置监听：当待重置的离开页完全滑出屏幕（与当前 page 差 ≥ 1.0）时重置它。
  ///
  /// onPageChanged 在 page 越过 50% 即触发，太早（图片半屏可见就被缩回）。这里改为
  /// 读连续浮点 page，只有离开页真正消失才重置 position/scaleState。若用户中途拖回，
  /// page 未达 1.0 差值，不重置，图片保持原状。
  void _onPageScroll() {
    final pending = _resetPendingIndex;
    if (pending == null || !_pageController.hasClients) return;
    final double? page = _pageController.page;
    if (page == null) return;
    if ((page - pending).abs() >= 1.0) {
      _resetPendingIndex = null;
      _controllers[pending].reset();
      _scaleStateControllers[pending].reset();
    }
  }

  /// PageView physics：始终允许翻页。放大态下 PhotoView 通过 shouldMove 在到边时
  /// 让出手势给 PageView，实现到边跟随手指翻页；未到边时 PhotoView 平移图片。
  ScrollPhysics get _physics => const BouncingScrollPhysics();

  /// 当前显示页索引。public 仅供测试断言翻页结果。
  @visibleForTesting
  int get currentPage => _currentIndex;

  /// 指定页的图片位移。public 仅供测试断言翻页重置结果。
  @visibleForTesting
  Offset pagePosition(int index) => _controllers[index].value.position;

  /// 编程式跳页（仅供测试）。触发 onPageChanged，验证翻页重置逻辑。
  @visibleForTesting
  void goToPage(int index) => _pageController.jumpToPage(index);

  /// 长按图片：弹出底部菜单（复用 PanelItem 样式，与加号面板视觉统一）。
  ///
  /// BottomSheet 顶部圆角 12、背景 #F7F7F7。点「保存图片」先 pop sheet 再异步
  /// 保存（标准 IM 交互，不让 sheet 卡住等异步下载）。
  void _showSaveSheet(LongPressStartDetails _) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      backgroundColor: const Color(0xFFF7F7F7),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 18, 8, 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              PanelItem(
                icon: Icons.download_for_offline_outlined,
                label: '保存图片',
                onTap: () async {
                  Navigator.pop(context);
                  await _doSave();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 保存当前页图片到相册，SnackBar 反馈结果。
  ///
  /// 取当前 _currentIndex 对应图（长按必发生在当前显示页，二者等价）。
  Future<void> _doSave() async {
    final image = widget.images[_currentIndex];
    final result = await saveToGallery(image);
    if (!mounted) return;
    showAppSnackBar(
      context,
      result == SaveResult.success ? '已保存到相册' : '保存失败，请稍后重试',
      type: result == SaveResult.success
          ? SnackBarType.success
          : SnackBarType.error,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // 外包 LongPressDetector（pointer 层，不进 arena），长按图片弹保存菜单。
      // 缩放/拖动移动超阈值自动取消长按，与 PhotoView 的手势隔离不冲突。
      body: LongPressDetector(
        onLongPressStart: _showSaveSheet,
        child: PhotoViewGallery.builder(
          pageController: _pageController,
          itemCount: widget.images.length,
          scrollPhysics: _physics,
          onPageChanged: (index) {
            final oldIndex = _currentIndex;
            setState(() {
              _currentIndex = index;
              // 切页后按新页的 scaleState 更新 _zoomed
              _updateZoomed(_scaleStateControllers[index].scaleState);
            });
            if (oldIndex != index) {
              // 快速连续翻页时，上一个待重置页此时必然已完全滑出，先重置它。
              final previousPending = _resetPendingIndex;
              if (previousPending != null && previousPending != index) {
                _controllers[previousPending].reset();
                _scaleStateControllers[previousPending].reset();
              }
              // 标记本次离开页待重置，等它完全滑出屏幕（_onPageScroll 判定）再执行，
              // 避免半屏可见时缩回原大小的突兀感。
              _resetPendingIndex = oldIndex;
            }
          },
          builder: (_, i) {
            final img = widget.images[i];
            return PhotoViewGalleryPageOptions(
              imageProvider: CachedNetworkImageProvider(
                img.url,
                headers: img.headers,
                // 画廊用原图（高清），与缩略图场景的 cacheKey 隔离（origin_ 前缀），
                // 避免缩略图小 bitmap 把原图大 bitmap 从内存 LRU 顶掉。
                // cacheKey 对齐后，同一张原图在同一会话内重复打开画廊会命中内存，
                // 无需重新解码——这正是根治「每次打开画廊重新加载」的关键。
                cacheKey: originCacheKey(img.fileId),
                // 注意：不加 cacheWidth。画廊支持 4× 手势缩放，需原图全分辨率
                // 保证放大后清晰。原图体积较大，靠 origin_ key 与缩略图隔离 +
                // 全局 ImageCache 上限控制总占用。
              ),
              controller: _controllers[i],
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 4,
              // 仅初始页注册 Hero：关闭时反向飞行只匹配当前显示页。
              heroAttributes: i == widget.initialIndex
                  ? PhotoViewHeroAttributes(tag: img.heroTag)
                  : null,
              onTapUp: (_, __, ___) => close(),
              scaleStateController: _scaleStateControllers[i],
            );
          },
          backgroundDecoration: const BoxDecoration(color: Colors.black),
        ),
      ),
    );
  }
}
