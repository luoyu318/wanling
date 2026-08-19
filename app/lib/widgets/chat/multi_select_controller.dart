import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/chat_provider.dart' show chatProvider;
import 'package:wanling_core/utils/chat/message_preview.dart' show extractMessageText;
import 'package:wanling_core/utils/snackbar.dart' show showAppSnackBar, SnackBarType;

/// [MultiSelectController] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次,把所有外部依赖打包传入,controller
/// 内部通过 `_ctx.xxx` 访问,实现解耦 + 可测试性(mock 本对象即可单测)。
@immutable
class MultiSelectContext {
  /// 用于 showAppSnackBar 提示(多选底部「复制」结果反馈)。
  final BuildContext Function() getContext;

  /// for chatProvider.read(批量复制时拿消息列表)。
  final WidgetRef ref;

  /// chatProvider family key。
  final ({String convId, String? agentId}) chatKey;

  /// 切多选状态时调(包 setState,触发 AppBar/底部栏/勾选框 rebuild)。
  final void Function(VoidCallback) onSetState;

  const MultiSelectContext({
    required this.getContext,
    required this.ref,
    required this.chatKey,
    required this.onSetState,
  });
}

/// 多选模式的状态 + 行为控制器(方案 A:Controller class + 依赖注入)。
///
/// 封装 chat_page 原有的多选相关字段(_selectionMode / _selectedIds)和 4 个
/// 方法(enterSelection / exitSelection / toggleSelect / batchCopy)。chat_page
/// 在 initState 创建,dispose 时由 GC 回收(无 Overlay 等需手动释放的资源)。
///
/// 设计见 docs/plans/2026-07-11-multi-select-controller-spec.md。
class MultiSelectController {
  final MultiSelectContext _ctx;

  MultiSelectController(this._ctx);

  /// 当前是否处于多选模式(控制 AppBar/底部栏/勾选框切换)。
  bool _selectionMode = false;

  /// 已勾选的消息 id 集合(Set 去重,顺序无关)。
  final Set<String> _selectedIds = {};

  /// 当前是否处于多选模式。
  bool get isSelectionMode => _selectionMode;

  /// 已勾选消息数。
  int get selectedCount => _selectedIds.length;

  /// [msgId] 是否在选中集合。
  bool isSelected(String msgId) => _selectedIds.contains(msgId);

  /// 选中 id 列表的副本(供 chat_page `_confirmDelete(ids)` 调用)。
  /// 返回副本而非内部引用,调用方修改不影响 controller 状态。
  List<String> get selectedIdsList => _selectedIds.toList();

  /// 从菜单「多选」按钮进入:清旧选中 + 预选当前消息 + 开多选模式。
  void enterSelection(String msgId) {
    _ctx.onSetState(() {
      _selectedIds
        ..clear()
        ..add(msgId);
      _selectionMode = true;
    });
  }

  /// 退出多选模式(用户点返回键 / PopScope / 删除成功后清选)。
  void exitSelection() {
    _ctx.onSetState(() {
      _selectedIds.clear();
      _selectionMode = false;
    });
  }

  /// 切换某条消息的勾选状态。
  void toggleSelect(String msgId) {
    _ctx.onSetState(() {
      if (_selectedIds.contains(msgId)) {
        _selectedIds.remove(msgId);
      } else {
        _selectedIds.add(msgId);
      }
    });
  }

  /// 多选底部「复制」:把选中消息文本换行拼接复制到剪贴板。
  /// 若选中全是图片/文件(无文本),提示「选中的消息无可复制文本」。
  Future<void> batchCopy() async {
    if (_selectedIds.isEmpty) return;
    final chatState = _ctx.ref.read(chatProvider(_ctx.chatKey));
    final texts = chatState.displayMessages
        .where((m) => _selectedIds.contains(m.id))
        .map(extractMessageText)
        .where((t) => t.isNotEmpty)
        .join('\n');
    if (texts.isEmpty) {
      showAppSnackBar(_ctx.getContext(), '选中的消息无可复制文本');
      return;
    }
    await Clipboard.setData(ClipboardData(text: texts));
    showAppSnackBar(_ctx.getContext(), '已复制', type: SnackBarType.success);
  }
}
