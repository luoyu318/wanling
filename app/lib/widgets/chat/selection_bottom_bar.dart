import 'package:flutter/material.dart';

/// 多选模式底部操作栏(复制 + 删除两个 IconButton)。
/// selectedCount=0 时两按钮置灰且 onPressed=null。
class SelectionBottomBar extends StatelessWidget {
  final int selectedCount;
  final VoidCallback? onBatchCopy;
  final VoidCallback? onConfirmDelete;

  const SelectionBottomBar({
    super.key,
    required this.selectedCount,
    this.onBatchCopy,
    this.onConfirmDelete,
  });

  bool get _hasSelection => selectedCount > 0;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Colors.grey.shade300)),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: const Icon(Icons.content_copy),
              color: _hasSelection ? Colors.black87 : Colors.grey,
              onPressed: _hasSelection ? onBatchCopy : null,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              color: _hasSelection ? const Color(0xFFFA5151) : Colors.grey,
              onPressed: _hasSelection ? onConfirmDelete : null,
            ),
          ],
        ),
      ),
    );
  }
}
