import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollview_observer/scrollview_observer.dart';

import '../../providers/chat_provider.dart' show chatProvider;
import '../../utils/chat/render_box_utils.dart' show globalRectOf, listViewRect;
import 'jump_controller.dart' show dualSliverBottomTarget;

/// [UnreadLocatorController] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次,把所有外部依赖打包传入,controller
/// 内部通过 `_ctx.xxx` 访问,实现解耦 + 可测试性。
@immutable
class UnreadLocatorContext {
  /// for chatProvider.read。
  final WidgetRef ref;

  /// chatProvider family key。
  final ({String convId, String? agentId}) chatKey;

  /// 替代 widget.mounted(dispose 后不再读 ref / 滚动)。
  final bool Function() isMounted;

  /// 滚动控制(读 hasClients / position.pixels)。
  final ScrollController Function() getScrollCtrl;

  /// SliverObserverController(jumpTo 翻页 + sliverContexts 自旋等待)。
  final SliverObserverController Function() getObserverController;

  /// 历史 sliver 的 BuildContext(未读消息在历史段,定位 historyMessages 用)。
  final BuildContext? Function() getHistorySliverContext;

  /// 消息气泡的 GlobalKey map(globalRectOf 拿 RenderBox)。
  final Map<String, GlobalKey> Function() getBubbleKeys;

  /// ListView 的 key(listViewRect 算视口可见区域)。
  final GlobalKey Function() getListViewKey;

  /// 当前 BuildContext(listViewRect 第二参)。
  final BuildContext Function() getContext;

  /// 定位完成后回调(chat_page 提供 loadMoreHistory + checkUnreadSeen)。
  ///
  /// 在 _isLocating 释放的同一 PostFrameCallback 中调用,既预加载一页历史
  /// (避免用户下滑立即触顶),又检查 firstUnread 已在视口内的未读(让浮标数
  /// 即时反映)。
  final VoidCallback onLocateComplete;

  const UnreadLocatorContext({
    required this.ref,
    required this.chatKey,
    required this.isMounted,
    required this.getScrollCtrl,
    required this.getObserverController,
    required this.getHistorySliverContext,
    required this.getBubbleKeys,
    required this.getListViewKey,
    required this.getContext,
    required this.onLocateComplete,
  });
}

/// 进入会话后定位第一条未读消息 + 视口可见性判断的状态/行为控制器
/// (方案 A:Controller class + 依赖注入)。
///
/// 封装 chat_page 原有的 2 个方法 + 1 个状态:
/// - [_isLocating] 状态(原 chat_page 字段)
/// - [scrollToFirstUnreadIfNeeded](原 _scrollToFirstUnreadIfNeeded)
/// - [isMessageInViewport](原 _isMessageInViewport)
///
/// chat_page 在 initState 创建。build 内 ref.listen(firstUnread) 触发
/// [scrollToFirstUnreadIfNeeded];_checkUnreadSeen / _onScrollNotification
/// 读 [isLocating] 判断是否在定位期间;_checkUnreadSeen 调
/// [isMessageInViewport] 判断消息是否进入视口。
class UnreadLocatorController {
  final UnreadLocatorContext _ctx;

  UnreadLocatorController(this._ctx);

  /// jumpTo 定位未读期间为 true,禁用 _onScroll 的 loadMore + _checkUnreadSeen。
  ///
  /// jumpTo 把 px 跳到接近 maxScrollExtent 处(firstUnread 是视觉顶部),
  /// 若不拦截 _onScroll 会把"px 接近顶部"当成"用户上滑加载历史",触发 loadMore。
  /// loadMore 的 pixels 校正又把 px 推到更顶,循环加载直到 hasMore=false,
  /// 把 firstUnread 推到列表中段(messages 累积成几十条),完全脱离定位意图。
  bool _isLocating = false;

  /// 当前是否在定位期间(chat_page 的 _checkUnreadSeen / _onScrollNotification 读)。
  bool get isLocating => _isLocating;

  /// 判断消息当前是否在 ListView 视口内(任何部分可见)。
  bool isMessageInViewport(String msgId) {
    final rect = globalRectOf(_ctx.getBubbleKeys()[msgId]);
    if (rect == null) return false;
    final viewport = listViewRect(_ctx.getListViewKey(), _ctx.getContext());
    return rect.bottom > viewport.top && rect.top < viewport.bottom;
  }

  /// 进入会话后定位到第一条未读消息。
  /// 由 chat_page build 内的 ref.listen 监听 firstUnreadMessageId 从
  /// null→非null 触发。
  void scrollToFirstUnreadIfNeeded() {
    debugPrint('[locateUnread] CALLED');
    final chatState = _ctx.ref.read(chatProvider(_ctx.chatKey));
    final firstUnreadId = chatState.firstUnreadMessageId;
    debugPrint('[locateUnread] firstUnreadId=$firstUnreadId');
    if (firstUnreadId == null) {
      debugPrint('[locateUnread] ABORT: firstUnreadId is null');
      return;
    }
    final scrollCtrl = _ctx.getScrollCtrl();
    if (!scrollCtrl.hasClients) {
      debugPrint('[locateUnread] ABORT: scrollCtrl has no clients');
      return;
    }

    // 在 historyMessages（newest-first）中找到第一条未读的 index。
    // 未读必在历史段（_initialize 把整页加载进 historyMessages，活跃段为空）。
    final index = chatState.historyMessages.indexWhere((m) => m.id == firstUnreadId);
    debugPrint(
      '[locateUnread] index=$index, historyMessages.length=${chatState.historyMessages.length}, '
      'historyMessages.first.id=${chatState.historyMessages.isEmpty ? null : chatState.historyMessages.first.id}',
    );
    if (index < 0) {
      debugPrint('[locateUnread] ABORT: firstUnreadId not found in historyMessages');
      return;
    }

    // firstUnread 就是最新历史(index==0,贴锚点):直接贴底,不做 30% 对齐。
    //
    // 背景:observer.jumpTo(alignment:0.3) 只在目标尚不可见时才滚动;
    // index==0 的目标本就在视口底部边缘(history[0] 贴锚点),observer 判定
    // "已在视口"只滚一小段(真机实测 px≈-34.8),30% 对齐从未执行,导致
    // history 底部 + live 顶部同时露出(上下 sliver 各半)。且历史不足一屏时
    // 几何上不可能把 index==0 对齐到 30% 而不越锚点。
    // 语义上 firstUnread 是最新一条 = 用户本就应在底部,直接复用无未读场景
    // 的贴底逻辑(dualSliverBottomTarget),行为一致。
    if (index == 0) {
      debugPrint(
        '[locateUnread] firstUnread is newest history (index=0), '
        'fallback to bottom (skip 30% align)',
      );
      _scrollToBottomForFirstUnread();
      return;
    }

    final observerController = _ctx.getObserverController();
    // Bug A 自旋等待:SliverViewObserver 内部 sliverContexts 在 initState 的
    // PostFrameCallback 中填充。即使我们用了 loading overlay 让 SliverViewObserver
    // 提前挂载,jumpTo 仍可能在 sliverContexts 还空时被调用 → 静默失败。
    if (observerController.sliverContexts.isEmpty) {
      debugPrint('[locateUnread] sliverContexts empty, retrying next frame');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_ctx.isMounted()) scrollToFirstUnreadIfNeeded();
      });
      return;
    }

    // 进入定位状态:禁用 _onScroll 触发的 loadMore
    _isLocating = true;

    // 第一步:用 observerController.jumpTo 把 firstUnread 拉进可视区让其渲染。
    // jumpTo 是 Future,内部会逐步翻页直到目标 index 进可见区。
    // sliverContext 指定历史 sliver（未读在 historyMessages 内）。
    final pxBefore = scrollCtrl.position.pixels;
    debugPrint(
      '[locateUnread] before jumpTo: px=$pxBefore, will jumpTo index=$index, '
      'sliverContexts=${observerController.sliverContexts.length}',
    );
    observerController
        .jumpTo(
      index: index,
      alignment: 0.3,
      sliverContext: _ctx.getHistorySliverContext(),
    )
        .then((_) async {
      // jumpTo 完成后 firstUnread 必然已渲染,BuildContext 可拿
      if (!_ctx.isMounted()) {
        _isLocating = false;
        debugPrint('[locateUnread] jumpTo completed but not mounted');
        return;
      }
      final key = _ctx.getBubbleKeys()[firstUnreadId];
      final ctx = key?.currentContext;
      if (ctx == null) {
        _isLocating = false;
        debugPrint(
          '[locateUnread] after jumpTo: still no ctx for $firstUnreadId',
        );
        return;
      }
      final pxBeforeEnsure = scrollCtrl.hasClients
          ? scrollCtrl.position.pixels
          : null;
      debugPrint(
        '[locateUnread] jumpTo done, calling ensureVisible, px before=$pxBeforeEnsure',
      );
      // 第二步:ensureVisible 精确对齐(无动画,消除视觉滚动感)。
      // jumpTo 的 alignment 不够精确,需 ensureVisible 兜底。
      // 但如果 jumpTo 已经把 firstUnread 拉进视口,ensureVisible 会反向
      // 滚到 sliver 末尾导致跳动,故仅在不在视口时兜底。
      if (isMessageInViewport(firstUnreadId)) {
        debugPrint('[locateUnread] jumpTo already in viewport, skip ensureVisible');
      } else {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.3,
          duration: Duration.zero,
          curve: Curves.easeOut,
        );
        if (_ctx.isMounted() && scrollCtrl.hasClients) {
          debugPrint(
            '[locateUnread] after ensureVisible: px=${scrollCtrl.position.pixels}',
          );
        }
      }
      // 释放定位状态,下一帧恢复 loadMore 监听 + 调 onLocateComplete
      // (预加载历史 + 检查已在视口内的未读)。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _isLocating = false;
        debugPrint('[locateUnread] _isLocating released');
        _ctx.onLocateComplete();
      });
    });
    final pxRightAfterJump = scrollCtrl.hasClients
        ? scrollCtrl.position.pixels
        : null;
    debugPrint('[locateUnread] rightAfter jumpTo call: px=$pxRightAfterJump');
  }

  /// firstUnread 即最新历史(index==0)时直接贴底(与无未读场景一致)。
  ///
  /// 目标由 [dualSliverBottomTarget] 计算(live 空 → max(minScrollExtent, -vd);
  /// live 非空 → maxScrollExtent),同步 _isLocating 生命周期 + onLocateComplete,
  /// 与 observer.jumpTo 分支的收尾一致(预加载历史 + 检查已见未读)。
  void _scrollToBottomForFirstUnread() {
    final scrollCtrl = _ctx.getScrollCtrl();
    if (!scrollCtrl.hasClients) {
      debugPrint('[locateUnread] (bottom fallback) no clients');
      return;
    }
    _isLocating = true;
    final pos = scrollCtrl.position;
    final chatState = _ctx.ref.read(chatProvider(_ctx.chatKey));
    final target = dualSliverBottomTarget(
      minScrollExtent: pos.minScrollExtent,
      maxScrollExtent: pos.maxScrollExtent,
      viewportDimension: pos.viewportDimension,
      liveEmpty: chatState.liveMessages.isEmpty,
    );
    debugPrint(
      '[locateUnread] (bottom fallback) jumpTo $target '
      '(min=${pos.minScrollExtent}, max=${pos.maxScrollExtent}, '
      'vd=${pos.viewportDimension}, liveEmpty=${chatState.liveMessages.isEmpty})',
    );
    scrollCtrl.jumpTo(target);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _isLocating = false;
      debugPrint('[locateUnread] (bottom fallback) _isLocating released');
      _ctx.onLocateComplete();
    });
  }
}
