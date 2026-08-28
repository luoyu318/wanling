import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/quote.dart';
import 'package:wanling_core/providers/chat_provider.dart' show chatProvider;
import 'package:wanling_core/utils/chat/message_preview.dart' show extractLocalPreview;
import 'package:wanling_core/utils/chat/render_box_utils.dart' show listViewRect;
import '../../widgets/feedback/app_dialog.dart' show showAppDialog;
import 'message_context_menu.dart'
    show
        MessageContextMenu,
        kMenuHeight,
        kMenuTailHalfWidth,
        kMenuVerticalBudget,
        menuWidthFor;
import 'menu_placement.dart' show MenuPlacement;

/// [MessageMenuController] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次,把所有外部依赖打包传入,controller
/// 内部通过 `_ctx.xxx` 访问,实现解耦 + 可测试性(mock 本对象即可单测)。
@immutable
class MessageMenuContext {
  /// 用于 `Overlay.of(context)` / `showAppDialog`。
  final BuildContext Function() getContext;

  /// ListView 的 GlobalKey,用于 [listViewRect] 算可见区。
  final GlobalKey Function() getListViewKey;

  /// 拿指定 msgId 气泡的屏幕矩形(null 表示未挂载/不可见)。
  /// chat_page 包一层 `globalRectOf(_bubbleKeys[msgId])`。
  final Rect? Function(String msgId) bubbleGlobalRect;

  /// 当前会话消息列表(滚动重算时按 id 查目标消息)。
  final List<ChatMessage> Function() getMessages;

  /// 当前用户 id(撤回可行性判断用)。
  final String Function() getCurrentUserId;

  /// 复制选区或全文(由菜单「复制」触发)。
  final Future<void> Function(ChatMessage msg) onCopySelectedOrFull;

  /// 删除/撤回确认(由菜单「删除」「撤回」触发,单条/批量共用)。
  final Future<void> Function(List<String> ids, {bool recall}) onConfirmDelete;

  /// 当前会话是否 agent_session(动态判断,convType 异步加载,不能构造时固定)。
  /// 为 true 时菜单隐藏「引用」/「撤回」,只保留复制/删除/多选。
  final bool Function() getIsAgentSession;

  /// 进入多选模式(由菜单「多选」触发)。
  final void Function(String msgId) onEnterSelectionMode;

  /// 菜单关闭时的副作用(清选区 + _selectedText 等 chat_page 跨职责状态)。
  final VoidCallback onMenuHide;

  /// chatProvider family key(用于 retrySend / setPendingQuote)。
  final ({String convId, String? agentId}) chatKey;

  /// for setPendingQuote / retrySend。
  final WidgetRef ref;

  const MessageMenuContext({
    required this.getContext,
    required this.getListViewKey,
    required this.bubbleGlobalRect,
    required this.getMessages,
    required this.getCurrentUserId,
    required this.onCopySelectedOrFull,
    required this.onConfirmDelete,
    required this.onEnterSelectionMode,
    required this.onMenuHide,
    required this.getIsAgentSession,
    required this.chatKey,
    required this.ref,
  });
}

/// 长按消息菜单的状态 + 行为控制器(方案 A:Controller class + 依赖注入)。
///
/// 封装 chat_page 原有的菜单相关字段(_menuEntry / _activeSelectMsgId /
/// _menuPlacement)和 7 个方法(show / hide / update / build / canRecall /
/// computePlacement / dispose)。chat_page 在 initState 创建,dispose 释放。
///
/// 跨职责字段(_bubbleKeys / _listViewKey / _selectionKey / _selectedText)
/// 保留在 chat_page,通过 [MessageMenuContext] 的回调注入。
///
/// 设计见 docs/plans/2026-07-11-message-menu-controller-design.md。
class MessageMenuController {
  final MessageMenuContext _ctx;

  MessageMenuController(this._ctx);

  /// 当前菜单的 Overlay 实例(null 表示菜单未打开)。
  OverlayEntry? _menuEntry;

  /// 当前长按选择态的消息 id(菜单关闭时清空)。
  String? _activeSelectMsgId;

  /// 当前菜单定位缓存(滚动时比较,变化才重建 OverlayEntry)。
  MenuPlacement? _menuPlacement;

  /// 菜单是否处于打开状态。
  bool get isMenuOpen => _menuEntry != null;

  /// 撤回时间窗(client UI 层判定;server 会再校验一次)。
  static const Duration _recallWindow = Duration(minutes: 5);

  /// 长按消息:显示浮动菜单(OverlayEntry,绝对定位锚钉在可见区内)。
  /// 选择由常驻 SelectableRegion 内置长按选词完成(落点选词+拉杆),本方法只弹菜单。
  void showMessageMenu(ChatMessage msg) {
    hideMessageMenu();
    // 菜单宽度按 item 数动态算(agent_session 隐藏引用/撤回,item 数更少)。
    final menuWidth = menuWidthFor(_menuItemCount(msg));
    final placement = _computeMenuPlacement(msg.id, menuWidth: menuWidth);
    if (placement == null) return; // 消息不在可见区,不弹菜单
    _activeSelectMsgId = msg.id;
    _menuPlacement = placement;
    _menuEntry = OverlayEntry(builder: (_) => buildMenu(msg, placement));
    Overlay.of(_ctx.getContext()).insert(_menuEntry!);
  }

  /// 失败消息的状态指示器点击:弹 dialog 确认是否重新发送。
  /// 仅 status=failed 时调(由调用方守卫)。
  void showFailedMenu(ChatMessage msg) {
    showAppDialog(
      context: _ctx.getContext(),
      title: '重新发送?',
      content: const Text('该消息发送失败,是否重新发送?'),
      confirmText: '重新发送',
      onConfirm: () {
        _ctx.ref
            .read(chatProvider(_ctx.chatKey).notifier)
            .retrySend(msg.id);
      },
    );
  }

  /// 关闭菜单 + 清状态 + 触发 [MessageMenuContext.onMenuHide] 副作用。
  void hideMessageMenu() {
    _menuEntry?.remove();
    _menuEntry = null;
    _activeSelectMsgId = null;
    _menuPlacement = null;
    _ctx.onMenuHide();
  }

  /// 滚动时动态调整菜单:消息出屏则关闭,定位变化则重建 OverlayEntry。
  void updateMenuOnScroll() {
    final msgId = _activeSelectMsgId;
    if (msgId == null || _menuEntry == null) return;
    final messages = _ctx.getMessages();
    if (messages.isEmpty) {
      // messages 全删后,菜单还指向已删消息 → 清理悬空菜单,不留死引用。
      hideMessageMenu();
      return;
    }
    final msg = messages.firstWhere(
      (m) => m.id == msgId,
      orElse: () => messages.first,
    );
    // 菜单宽度按 item 数动态算,跟 showMessageMenu 同口径。
    final menuWidth = menuWidthFor(_menuItemCount(msg));
    final newPlacement = _computeMenuPlacement(msgId, menuWidth: menuWidth);
    if (newPlacement == null) {
      hideMessageMenu();
      return;
    }
    // 定位没变就不重建(滚动每帧都触发,避免无谓重建)
    if (_menuPlacement == newPlacement) return;
    _menuPlacement = newPlacement;
    // 重建 OverlayEntry 让菜单重新定位(绝对定位随滚动重算 top/left)
    _menuEntry!.remove();
    _menuEntry = OverlayEntry(builder: (_) => buildMenu(msg, newPlacement));
    Overlay.of(_ctx.getContext()).insert(_menuEntry!);
  }

  /// 构造 [MessageContextMenu] widget。由 OverlayEntry.builder 调用。
  Widget buildMenu(ChatMessage msg, MenuPlacement p) {
    // agent_session:隐藏引用/撤回(引用语义不适用,撤回由 stop bar 承载),
    // 只保留复制/删除/多选。canRecall 仍单独判断,非 agent_session 不受影响。
    final isAgentSession = _ctx.getIsAgentSession();
    final canRecallFlag = !isAgentSession && canRecall(msg);
    return MessageContextMenu(
      left: p.left,
      top: p.top,
      tailOffsetX: p.tailOffsetX,
      pointDown: p.pointDown,
      canRecall: canRecallFlag,
      showQuote: !isAgentSession,
      onCopy: () {
        _ctx.onCopySelectedOrFull(msg);
        hideMessageMenu();
      },
      // 「引用」:用本地数据拼 Quote snapshot 写入 pendingQuote。
      // server 富化时会用权威 quote 覆盖(extractPreview 同规则,server 富化幂等)。
      onQuote: () {
        final quote = Quote(
          messageId: msg.id,
          senderType: msg.senderType,
          senderId: msg.senderId,
          senderName: msg.senderName ?? '',
          msgType: msg.content['msg_type'] ?? 'text',
          preview: extractLocalPreview(msg),
        );
        _ctx.ref
            .read(chatProvider(_ctx.chatKey).notifier)
            .setPendingQuote(quote);
        hideMessageMenu();
      },
      // 「删除」永远走 hide 语义(per-participant 单向隐藏);
      // 「撤回」走 recall 语义(deleted_at 双向软删),仅在 canRecall 时出现。
      onDelete: () {
        hideMessageMenu();
        _ctx.onConfirmDelete([msg.id]);
      },
      onRecall: () {
        hideMessageMenu();
        _ctx.onConfirmDelete([msg.id], recall: true);
      },
      onSelect: () {
        hideMessageMenu();
        _ctx.onEnterSelectionMode(msg.id);
      },
      onDismiss: hideMessageMenu,
    );
  }

  /// 撤回可行性:自己发的 + sent 状态 + 5 分钟内。
  /// server 端会再校验一次(sender + 时限),client 这层只控制 UI 是否显示「撤回」。
  bool canRecall(ChatMessage msg) {
    final me = _ctx.getCurrentUserId();
    if (me.isEmpty || msg.senderId != me) return false;
    // sending/failed 状态的消息还没在 server 持久化,撤回会 404。
    // 必须等 status=sent(拿到 server messageId)才能撤回。
    if (msg.status != MessageStatus.sent) return false;
    return DateTime.now().difference(msg.createdAt) <= _recallWindow;
  }

  /// 菜单 item 数(决定菜单宽度):
  /// - agent_session: 复制/删除/多选 = 3(引用/撤回不适用)
  /// - 普通会话 canRecall=true: 复制/引用/删除/撤回/多选 = 5
  /// - 普通会话 canRecall=false: 复制/引用/删除/多选 = 4
  int _menuItemCount(ChatMessage msg) {
    if (_ctx.getIsAgentSession()) return 3;
    return canRecall(msg) ? 5 : 4;
  }

  /// 计算菜单定位(left/top/tailOffsetX/pointDown,全屏幕绝对坐标)。
  /// 消息不在可见区返回 null。
  ///
  /// **锚钉效果**:菜单跟随消息(贴在消息上/下方),但用 clamp 钉在可见区边缘,
  /// 不溢出 AppBar/输入栏。消息在中央时跟随;消息接近边缘时钉住。
  ///
  /// - top: 菜单顶缘屏幕 y = clamp(期望Y, viewport.top, viewport.bottom - menuH)
  /// - left: 菜单左缘屏幕 x,居中于消息中心并 clamp 不超屏
  /// - tailOffsetX: 三角在菜单内的位置,指向消息中心
  /// - pointDown: 菜单在消息上方→三角朝下
  ///
  /// [menuWidth] 由调用方按「canRecall ? 5 : 4」item 数算(menuWidthFor),
  /// 决定 clamp 边界,影响三角的水平定位。
  MenuPlacement? _computeMenuPlacement(
    String msgId, {
    required double menuWidth,
  }) {
    final rect = _ctx.bubbleGlobalRect(msgId);
    if (rect == null) return null;

    // 可见区 = ListView 在屏幕的矩形(扣除 AppBar 和输入栏)。
    final viewport = listViewRect(_ctx.getListViewKey(), _ctx.getContext());

    // 出屏判定:消息完全在可见区外 → 取消菜单
    if (rect.bottom <= viewport.top || rect.top >= viewport.bottom) {
      return null;
    }

    // 上下方向 + 期望 Y:优先上方(菜单贴消息上方),不够则下方,都不够选大的。
    // 期望上方 Y = rect.top - 预算(菜单高+三角+间距)
    // 期望下方 Y = rect.bottom + 间距(8)
    final preferTop = rect.top - kMenuVerticalBudget;
    final preferBottom = rect.bottom + 8;
    final spaceAbove = rect.top - viewport.top;
    final spaceBelow = viewport.bottom - rect.bottom;
    double desiredTop;
    bool pointDown;
    if (spaceAbove >= kMenuVerticalBudget) {
      // 上方够:菜单贴消息上方,三角朝下
      desiredTop = preferTop;
      pointDown = true;
    } else if (spaceBelow >= kMenuVerticalBudget) {
      // 下方够:菜单贴消息下方,三角朝上
      desiredTop = preferBottom;
      pointDown = false;
    } else {
      // 上下都不够(消息极长占满可见区):选空间大的一边,钉边缘。
      if (spaceAbove >= spaceBelow) {
        desiredTop = preferTop;
        pointDown = true;
      } else {
        desiredTop = preferBottom;
        pointDown = false;
      }
    }
    // 锚钉核心:clamp 期望 Y 到可见区内,菜单不溢出 AppBar/输入栏。
    // 消息在中央时 clamp 不生效(跟随);消息溢出时钉在 viewport 边缘。
    final top = desiredTop.clamp(viewport.top, viewport.bottom - kMenuHeight);

    // 水平:菜单居中于消息中心,clamp 不超可见区左右。
    final left = (rect.center.dx - menuWidth / 2).clamp(
      viewport.left + 8,
      viewport.right - menuWidth - 8,
    );
    // 三角指向消息中心:菜单内 x = 消息中心 - 菜单左缘
    final tailOffsetX = (rect.center.dx - left).clamp(
      kMenuTailHalfWidth,
      menuWidth - kMenuTailHalfWidth,
    );

    return MenuPlacement(
      left: left,
      top: top,
      tailOffsetX: tailOffsetX,
      pointDown: pointDown,
    );
  }

  /// 清理 OverlayEntry(chat_page dispose 时调)。
  /// 仅移除 Overlay,不触发 [MessageMenuContext.onMenuHide](页面已销毁,
  /// 不需要也不应该再清选区 widget 状态)。
  void dispose() {
    _menuEntry?.remove();
    _menuEntry = null;
  }
}
