import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/chat_provider.dart' show chatProvider, ChatNotifier;
import 'package:wanling_core/utils/debug_log.dart';

/// [LoadMoreController] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次,把所有外部依赖打包传入,controller
/// 内部通过 `_ctx.xxx` 访问,实现解耦 + 可测试性。
@immutable
class LoadMoreContext {
  /// for chatProvider.read。
  final WidgetRef ref;

  /// chatProvider family key。
  final ({String convId, String? agentId}) chatKey;

  /// 滚动控制器(从 chat_page 读 position / hasClients)。
  final ScrollController Function() getScrollCtrl;

  /// 定位中不触发 loadMore(从 UnreadLocatorController 读)。
  final bool Function() isLocating;

  /// chatState 的 notifier,调 loadMoreHistory。
  final ChatNotifier Function() getNotifier;

  const LoadMoreContext({
    required this.ref,
    required this.chatKey,
    required this.getScrollCtrl,
    required this.isLocating,
    required this.getNotifier,
  });
}

/// 历史消息预加载(loadMore)触发控制器(方案 A:Controller class + 依赖注入)。
///
/// 封装 chat_page 原有的 2 个方法 + 1 个状态字段:
/// - [_isUserScrolling] 状态(原 chat_page 字段)
/// - [onScrollNotification](原 _onScrollNotification)
/// - [loadMore](原 _loadMore)
///
/// chat_page 在 initState 创建(_unreadTracker 之后,依赖 UnreadLocatorController
/// 的 isLocating)。无资源需手动 dispose。
class LoadMoreController {
  final LoadMoreContext _ctx;

  LoadMoreController(this._ctx);

  /// 用户主导的滚动事件处理：触发 50% 阈值预加载。
  ///
  /// **区分用户滚动 vs 程序动画的关键**：
  /// 用 `ScrollStartNotification.dragDetails` 一次性判断本次滚动链路是否由
  /// 用户手指触发。[_isUserScrolling] 标记整个滚动链路（含手指松开后的 fling
  /// 惯性），让 fling 期间也能触发预加载——这是核心修复点。
  ///
  /// **为什么不能直接用 ScrollUpdateNotification.dragDetails**：
  /// fling 期间 dragDetails=null，所有 ScrollUpdateNotification 被过滤，导致
  /// 50% 阈值完全失效（用户 fling 下滑时只能等触顶 overdrag 才触发，等于
  /// 没有预加载）。
  ///
  /// **链式触发**：一次手势内允许多次 loadMore，靠 `state.isLoadingMore` 防抖
  /// （加载期间不重复触发，加载完成下一帧若仍 < threshold 立即再触发）。
  /// 适合用户长距离 fling 跨越多页的场景，避免触顶。
  ///
  /// **触发条件**：
  /// - [_isUserScrolling]（用户主导，含 fling 惯性）
  /// - 距视觉顶部 ≤ 50% 视口高度（预加载，对齐主流 IM）
  /// - state.isLoadingMore=false + hasMore=true（防抖 + 终止条件）
  ///
  /// [LoadMoreContext.isLocating] flag 在定位期间禁用本回调，避免 jumpTo 把 px
  /// 推到 minScrollExtent 附近（center 几何下视觉顶部 = 最老 = minScrollExtent）
  /// 时误触发 loadMore。
  bool _isUserScrolling = false;

  bool onScrollNotification(ScrollNotification notification) {
    if (_ctx.isLocating()) return false;
    final scrollCtrl = _ctx.getScrollCtrl();
    if (!scrollCtrl.hasClients) return false;

    // 滚动开始：判断本次滚动是否用户主导（dragDetails != null 表示手指触发）
    // 标记整个滚动链路（含 fling 惯性）为用户主导
    if (notification is ScrollStartNotification) {
      _isUserScrolling = notification.dragDetails != null;
      if (notification.dragDetails == null) {
        debugLog(
          '[scrollStart] programmatic scroll (dragDetails=null) '
          'px=${scrollCtrl.position.pixels}',
        );
      }
      return false;
    }

    if (notification is ScrollEndNotification) {
      debugLog(
        '[scrollEnd] px=${scrollCtrl.position.pixels} '
        'userScrolling=$_isUserScrolling',
      );
      _isUserScrolling = false;
      return false;
    }

    if (notification is! ScrollUpdateNotification) return false;
    if (!_isUserScrolling) return false;

    final chatState = _ctx.ref.read(chatProvider(_ctx.chatKey));
    if (chatState.isLoadingMore || !chatState.hasMore) return false;

    // 预加载阈值：距视觉顶部剩余 ≤ 50% 视口高度就触发。配合 _pageSize=100
    // 和首屏预加载，用户下滑有充足缓冲，避免触顶。
    final px = scrollCtrl.position.pixels;
    final minExtent = scrollCtrl.position.minScrollExtent;
    final viewport = scrollCtrl.position.viewportDimension;
    final distanceToTop = px - minExtent;
    final threshold = viewport * 0.5;
    if (distanceToTop > threshold) {
      debugLog(
        '[scrollUpdate] near top but not trigger: distanceToTop=$distanceToTop '
        'threshold=$threshold userScrolling=$_isUserScrolling',
      );
      return false;
    }

    debugLog(
      '[scrollUpdate] TRIGGER loadMore: distanceToTop=$distanceToTop, '
      'threshold=$threshold, viewport=$viewport, minExtent=$minExtent, '
      'px=$px',
    );
    loadMore();
    return false;
  }

  /// 上滑加载更早的历史消息。
  ///
  /// 双 sliver 几何:historySliver 是反向 sliver(等同 reverse ListView 行为),
  /// loadMore append 到 historyMessages 末尾 → minScrollExtent 更负 → px 不动 → 不顶内容。
  /// 无需 standby 补偿(center 几何下增长朝远离锚点方向,天然不动)。
  Future<void> loadMore() async {
    final chatState = _ctx.ref.read(chatProvider(_ctx.chatKey));
    debugLog(
      '[loadMore] CHECK: isLoadingMore=${chatState.isLoadingMore}, '
      'hasMore=${chatState.hasMore}',
    );
    if (chatState.isLoadingMore || !chatState.hasMore) return;
    await _ctx.getNotifier().loadMoreHistory();
  }
}
