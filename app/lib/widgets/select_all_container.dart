import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// "全选或全不选"的 [SelectionContainer] 包装。
///
/// 把一个块级子树（代码块 / 表格 / LaTeX 块）包成一个**整体可选单元**：
/// 当用户拖动选择拉杆与块的矩形相交时，整个块被全选（主流 IM 式），而不是
/// 只选中块内部分文字。块内无文字可选时（如 LaTeX 图形），配合 [fallbackText]
/// 复制出源码。
///
/// 实现照搬 Flutter 官方示例
/// `flutter/examples/api/lib/material/selection_container/selection_container.0.dart`
/// 的 `SelectAllOrNoneContainerDelegate`，它是 `MultiSelectableSelectionContainerDelegate`
/// 的子类，父类已实现注册/布局/handle 渲染等全部基础逻辑，子类只 override 选择策略。
///
/// 用法：
/// ```dart
/// SelectAllOrNoneContainer(
///   fallbackText: code, // 块无文本时复制兜底
///   child: 代码块 widget,
/// )
/// ```
class SelectAllOrNoneContainer extends StatefulWidget {
  final Widget child;

  /// 块内无可选文本时的复制兜底（如 LaTeX 图形）。null 则不兜底。
  ///
  /// 普通代码块/表格内部是 TextSpan，天然可选，无需兜底。
  final String? fallbackText;

  const SelectAllOrNoneContainer({
    super.key,
    required this.child,
    this.fallbackText,
  });

  @override
  State<SelectAllOrNoneContainer> createState() =>
      _SelectAllOrNoneContainerState();
}

class _SelectAllOrNoneContainerState extends State<SelectAllOrNoneContainer> {
  late final SelectAllOrNoneContainerDelegate delegate;

  @override
  void initState() {
    super.initState();
    delegate = SelectAllOrNoneContainerDelegate();
    delegate.fallbackText = widget.fallbackText;
  }

  @override
  void didUpdateWidget(SelectAllOrNoneContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fallbackText != widget.fallbackText) {
      delegate.fallbackText = widget.fallbackText;
    }
  }

  @override
  void dispose() {
    delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 块内有文本时：直接 SelectionContainer 包 child（child 内的 Text 参与
    // 选择，复制得代码源码）。
    // 块内无文本（LaTeX 图形）时：额外叠一个不可见但可选的 Text(fallbackText)
    // 作为被选中的文本载体，复制得 latex 源码。
    Widget effective = widget.child;
    if (widget.fallbackText != null && widget.fallbackText!.isNotEmpty) {
      // 不可见的可选文本：尺寸 0、透明，但仍注册为 Selectable。
      // 全选时它被选中 → getSelectedContent 拿到 fallbackText。
      effective = Stack(
        children: [
          widget.child,
          Positioned(
            left: 0,
            top: 0,
            child: ExcludeFocus(
              child: Opacity(
                opacity: 0,
                child: Text(
                  widget.fallbackText!,
                  // 极小尺寸避免影响布局
                  style: const TextStyle(fontSize: 1),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return SelectionContainer(delegate: delegate, child: effective);
  }
}

/// "全选或全不选"策略 delegate。
///
/// - [handleSelectWord]：长按/双击落块内 → 当作全选整块
/// - [handleSelectionEdgeUpdate]：拖动拉杆与块矩形相交 → 全选整块；否则清空
/// - [handleSelectAll]：外层 SelectableRegion.selectAll 传播进来 → 全选
class SelectAllOrNoneContainerDelegate
    extends MultiSelectableSelectionContainerDelegate {
  Offset? _adjustedStartEdge;
  Offset? _adjustedEndEdge;
  bool _isSelected = false;

  /// 块内无可选文本时，复制兜底文本（由容器 widget 注入）。
  String? fallbackText;

  // 新加入的 selectable 若当前已处于选中态，立刻派发全选事件。
  @override
  void ensureChildUpdated(Selectable selectable) {
    if (_isSelected) {
      dispatchSelectionEventToChild(
          selectable, const SelectAllSelectionEvent());
    }
  }

  // 长按/双击落块内 → 当作全选。
  @override
  SelectionResult handleSelectWord(SelectWordSelectionEvent event) {
    return handleSelectAll(const SelectAllSelectionEvent());
  }

  @override
  SelectionResult handleSelectionEdgeUpdate(SelectionEdgeUpdateEvent event) {
    final containerRect = Rect.fromLTWH(
      0,
      0,
      containerSize.width,
      containerSize.height,
    );
    final globalToLocal = getTransformTo(null)..invert();
    final localOffset =
        MatrixUtils.transformPoint(globalToLocal, event.globalPosition);
    final adjustOffset =
        SelectionUtils.adjustDragOffset(containerRect, localOffset);
    if (event.type == SelectionEventType.startEdgeUpdate) {
      _adjustedStartEdge = adjustOffset;
    } else {
      _adjustedEndEdge = adjustOffset;
    }
    // 拉杆选区与块矩形相交 → 全选；否则清空。
    if (_adjustedStartEdge != null && _adjustedEndEdge != null) {
      final selectionRect =
          Rect.fromPoints(_adjustedStartEdge!, _adjustedEndEdge!);
      if (!selectionRect.intersect(containerRect).isEmpty) {
        handleSelectAll(const SelectAllSelectionEvent());
      } else {
        super.handleClearSelection(const ClearSelectionEvent());
      }
    } else {
      super.handleClearSelection(const ClearSelectionEvent());
    }
    return SelectionUtils.getResultBasedOnRect(containerRect, localOffset);
  }

  @override
  SelectionResult handleClearSelection(ClearSelectionEvent event) {
    _adjustedStartEdge = null;
    _adjustedEndEdge = null;
    _isSelected = false;
    return super.handleClearSelection(event);
  }

  @override
  SelectionResult handleSelectAll(SelectAllSelectionEvent event) {
    _isSelected = true;
    return super.handleSelectAll(event);
  }
}
