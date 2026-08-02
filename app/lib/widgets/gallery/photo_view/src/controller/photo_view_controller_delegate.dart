import 'package:flutter/widgets.dart';
import 'package:app/widgets/gallery/photo_view/photo_view.dart'
    show
        PhotoViewControllerBase,
        PhotoViewScaleState,
        PhotoViewScaleStateController,
        ScaleStateCycle;
import 'package:app/widgets/gallery/photo_view/src/core/photo_view_core.dart';
import 'package:app/widgets/gallery/photo_view/src/photo_view_scale_state.dart';
import 'package:app/widgets/gallery/photo_view/src/utils/photo_view_utils.dart';

/// A  class to hold internal layout logic to sync both controller states
///
/// It reacts to layout changes (eg: enter landscape or widget resize) and syncs the two controllers.
mixin PhotoViewControllerDelegate on State<PhotoViewCore> {
  PhotoViewControllerBase get controller => widget.controller;

  PhotoViewScaleStateController get scaleStateController =>
      widget.scaleStateController;

  ScaleBoundaries get scaleBoundaries => widget.scaleBoundaries;

  ScaleStateCycle get scaleStateCycle => widget.scaleStateCycle;

  Alignment get basePosition => widget.basePosition;
  Function(double prevScale, double nextScale)? _animateScale;

  /// Mark if scale need recalculation, useful for scale boundaries changes.
  bool markNeedsScaleRecalc = true;

  void initDelegate() {
    controller.addIgnorableListener(_blindScaleListener);
    scaleStateController.addIgnorableListener(_blindScaleStateListener);
  }

  void _blindScaleStateListener() {
    if (!scaleStateController.hasChanged) {
      return;
    }
    if (_animateScale == null || scaleStateController.isZooming) {
      controller.setScaleInvisibly(scale);
      return;
    }
    final double prevScale = controller.scale ??
        getScaleForScaleState(
          scaleStateController.prevScaleState,
          scaleBoundaries,
        );

    final double nextScale = getScaleForScaleState(
      scaleStateController.scaleState,
      scaleBoundaries,
    );

    _animateScale!(prevScale, nextScale);
  }

  void addAnimateOnScaleStateUpdate(
    void animateScale(double prevScale, double nextScale),
  ) {
    _animateScale = animateScale;
  }

  void _blindScaleListener() {
    // 不在此钳制 position。平移过程中的位置约束由 onScaleUpdate 的 clampPosition
    // 处理（按当前 scale 计算边界）。此处若再覆盖，双指缩放时（scale 持续变化）
    // 会与 onScaleUpdate 在同一帧内交替写 position，导致图片高频跳变频闪。
    if (controller.scale == controller.prevValue.scale) {
      return;
    }
    final PhotoViewScaleState newScaleState =
        (scale > scaleBoundaries.initialScale)
            ? PhotoViewScaleState.zoomedIn
            : PhotoViewScaleState.zoomedOut;

    scaleStateController.setInvisibly(newScaleState);
  }

  Offset get position => controller.position;

  double get scale {
    // for figuring out initial scale
    final needsRecalc = markNeedsScaleRecalc &&
        !scaleStateController.scaleState.isScaleStateZooming;

    final scaleExistsOnController = controller.scale != null;
    if (needsRecalc || !scaleExistsOnController) {
      final newScale = getScaleForScaleState(
        scaleStateController.scaleState,
        scaleBoundaries,
      );
      markNeedsScaleRecalc = false;
      scale = newScale;
      return newScale;
    }
    return controller.scale!;
  }

  set scale(double scale) => controller.setScaleInvisibly(scale);

  void updateMultiple({
    Offset? position,
    double? scale,
    double? rotation,
    Offset? rotationFocusPoint,
  }) {
    controller.updateMultiple(
      position: position,
      scale: scale,
      rotation: rotation,
      rotationFocusPoint: rotationFocusPoint,
    );
  }

  void updateScaleStateFromNewScale(double newScale) {
    PhotoViewScaleState newScaleState = PhotoViewScaleState.initial;
    if (scale != scaleBoundaries.initialScale) {
      newScaleState = (newScale > scaleBoundaries.initialScale)
          ? PhotoViewScaleState.zoomedIn
          : PhotoViewScaleState.zoomedOut;
    }
    scaleStateController.setInvisibly(newScaleState);
  }

  void nextScaleState() {
    final PhotoViewScaleState scaleState = scaleStateController.scaleState;
    if (scaleState == PhotoViewScaleState.zoomedIn ||
        scaleState == PhotoViewScaleState.zoomedOut) {
      scaleStateController.scaleState = scaleStateCycle(scaleState);
      return;
    }
    final double originalScale = getScaleForScaleState(
      scaleState,
      scaleBoundaries,
    );

    double prevScale = originalScale;
    PhotoViewScaleState prevScaleState = scaleState;
    double nextScale = originalScale;
    PhotoViewScaleState nextScaleState = scaleState;

    do {
      prevScale = nextScale;
      prevScaleState = nextScaleState;
      nextScaleState = scaleStateCycle(prevScaleState);
      nextScale = getScaleForScaleState(nextScaleState, scaleBoundaries);
    } while (prevScale == nextScale && scaleState != nextScaleState);

    if (originalScale == nextScale) {
      return;
    }
    scaleStateController.scaleState = nextScaleState;
  }

  CornersRange cornersX({double? scale}) {
    final double _scale = scale ?? this.scale;

    final double computedWidth = scaleBoundaries.childSize.width * _scale;
    final double screenWidth = scaleBoundaries.outerSize.width;

    final double positionX = basePosition.x;
    final double widthDiff = computedWidth - screenWidth;

    final double minX = ((positionX - 1).abs() / 2) * widthDiff * -1;
    final double maxX = ((positionX + 1).abs() / 2) * widthDiff;
    return CornersRange(minX, maxX);
  }

  CornersRange cornersY({double? scale}) {
    final double _scale = scale ?? this.scale;

    final double computedHeight = scaleBoundaries.childSize.height * _scale;
    final double screenHeight = scaleBoundaries.outerSize.height;

    final double positionY = basePosition.y;
    final double heightDiff = computedHeight - screenHeight;

    final double minY = ((positionY - 1).abs() / 2) * heightDiff * -1;
    final double maxY = ((positionY + 1).abs() / 2) * heightDiff;
    return CornersRange(minY, maxY);
  }

  Offset clampPosition({Offset? position, double? scale}) {
    final double _scale = scale ?? this.scale;
    final Offset _position = position ?? this.position;

    final double computedWidth = scaleBoundaries.childSize.width * _scale;
    final double computedHeight = scaleBoundaries.childSize.height * _scale;

    final double screenWidth = scaleBoundaries.outerSize.width;
    final double screenHeight = scaleBoundaries.outerSize.height;

    double finalX = 0.0;
    if (screenWidth < computedWidth) {
      final cornersX = this.cornersX(scale: _scale);
      finalX = _position.dx.clamp(cornersX.min, cornersX.max);
    }

    double finalY = 0.0;
    if (screenHeight < computedHeight) {
      final cornersY = this.cornersY(scale: _scale);
      finalY = _position.dy.clamp(cornersY.min, cornersY.max);
    }

    return Offset(finalX, finalY);
  }

  @override
  void dispose() {
    _animateScale = null;
    controller.removeIgnorableListener(_blindScaleListener);
    scaleStateController.removeIgnorableListener(_blindScaleStateListener);
    super.dispose();
  }
}
