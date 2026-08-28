import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollview_observer/scrollview_observer.dart';

import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart' show chatProvider;
import 'package:wanling_core/services/api_service.dart'
    show ApiService, MessageContext, MessageNotFoundException, NoAccessException;
import 'package:wanling_core/utils/snackbar.dart' show showAppSnackBar, SnackBarType;

/// 双 sliver center 几何下「最新消息贴底」的目标 px。
///
/// CustomScrollView(center=live) 的 maxScrollExtent = max(0, trailingExtent - vd)
/// (见 viewport.dart:1734)。既有会话首屏 live 空 → trailingExtent=0 →
/// maxScrollExtent=0,指向空 center 顶部而非最新消息。本函数按 live 是否为空
/// 切换底部目标:
/// - live 非空(会话中有活跃消息): 正向 sliver 末尾 = maxScrollExtent,newest 天然贴底;
/// - live 空(纯历史): newest 在 leading(坐标 0 上方),贴底需 px=-vd 让 newest
///   对齐 viewport 底部,clamp 到 minScrollExtent 防历史不足一屏时越界。
///
/// scrollToBottom / _isAtBottom / 流式跟随 / 初始定位统一调用本函数,
/// 避免四处各自判断 live 空/非空导致目标不一致(scrollToBottom 到 0 而真实底部
/// 在 -vd,表现为「点好几次才到底」)。
double dualSliverBottomTarget({
  required double minScrollExtent,
  required double maxScrollExtent,
  required double viewportDimension,
  required bool liveEmpty,
}) {
  if (!liveEmpty) return maxScrollExtent;
  return math.max(minScrollExtent, -viewportDimension);
}

/// [JumpController] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次,把所有外部依赖打包传入,controller
/// 内部通过 `_ctx.xxx` 访问,实现解耦 + 可测试性(mock 本对象即可单测)。
@immutable
class JumpContext {
  /// showAppSnackBar(跳转中 / 失败提示)。
  final BuildContext Function() getContext;

  /// for chatProvider.read / apiProvider.read。
  final WidgetRef ref;

  /// chatProvider family key。
  final ({String convId, String? agentId}) chatKey;

  /// 高亮 / 清空高亮时 setState(触发 rebuild 让 _buildMessageRow 重绘高亮背景)。
  final void Function(VoidCallback) onSetState;

  /// 替代 widget.mounted(dispose 后不再 setState / 滚动 / 读 ref)。
  final bool Function() isMounted;

  /// 滚动控制(滚动到底部用)。
  final ScrollController Function() getScrollCtrl;

  /// 活跃 sliver(liveMessages)是否为空。dualSliverBottomTarget 据此切换底部目标:
  /// live 空(既有会话首屏)底部在 leading 侧(-vd),live 非空(会话中)底部在 trailing 侧(maxScrollExtent)。
  final bool Function() getLiveEmpty;

  /// SliverObserverController(jumpTo 翻页用,跨 sliver 定位到目标 index)。
  final SliverObserverController Function() getObserverController;

  /// 活跃 sliver 的 BuildContext(从 SliverList 的 itemBuilder 捕获,
  /// findRenderObject 返回 RenderSliverList,供 jumpTo 在该 sliver 内定位)。
  final BuildContext? Function() getLiveSliverContext;

  /// 历史 sliver 的 BuildContext(同上,定位 historyMessages 用)。
  final BuildContext? Function() getHistorySliverContext;

  /// 消息气泡的 GlobalKey map(ensureVisible 拿 BuildContext 用)。
  final Map<String, GlobalKey> Function() getBubbleKeys;

  const JumpContext({
    required this.getContext,
    required this.ref,
    required this.chatKey,
    required this.onSetState,
    required this.isMounted,
    required this.getScrollCtrl,
    required this.getLiveEmpty,
    required this.getObserverController,
    required this.getLiveSliverContext,
    required this.getHistorySliverContext,
    required this.getBubbleKeys,
  });
}

/// 跳转引用消息 + 高亮 flash + 滚动到底部的状态 + 行为控制器
/// (方案 A:Controller class + 依赖注入)。
///
/// 封装 chat_page 原有的 4 个方法:
/// - [_highlightedMessageId] 状态(原 chat_page 字段)
/// - [highlightMessage](原 _highlightMessage)
/// - [scrollToMessageIndex](原 _scrollToMessageIndex)
/// - [jumpToMessage](原 _jumpToMessage)
/// - [scrollToBottom](原 _doScrollToBottom)
///
/// chat_page 在 initState 创建,dispose 时 cancel 高亮 Timer(避免
/// setState-after-dispose)。build 方法读 [highlightedMessageId] getter
/// 决定是否为匹配消息包高亮背景。
class JumpController {
  final JumpContext _ctx;

  JumpController(this._ctx);

  /// 跳转引用块时高亮的目标消息 id(1s 后清空,触发 flash 视觉反馈)。
  /// null 表示无高亮。
  String? _highlightedMessageId;

  /// 1s 后清空高亮的定时器。dispose 时 cancel,避免页面退出后 setState。
  Timer? _highlightTimer;

  /// 当前高亮的消息 id(只读)。chat_page build 据此为匹配消息包高亮背景。
  String? get highlightedMessageId => _highlightedMessageId;

  /// 高亮目标消息 1s,触发视觉 flash 反馈。
  ///
  /// onSetState 写入 [_highlightedMessageId] 让 _buildMessageRow 为匹配消息
  /// 包高亮背景;1s 后 onSetState 清空,flash 消失。
  ///
  /// 用 [Timer] 而非 Future.delayed,dispose 时可 cancel(避免页面退出后
  /// setState-after-dispose)。行为等价。
  void highlightMessage(String messageId) {
    if (!_ctx.isMounted()) return;
    _ctx.onSetState(() => _highlightedMessageId = messageId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 1), () {
      if (_ctx.isMounted()) {
        _ctx.onSetState(() => _highlightedMessageId = null);
      }
    });
  }

  /// 把目标 index 滚到视口 alignment=0.3 处(离 AppBar 一条消息距离)。
  ///
  /// 两步精确对齐:
  /// 1. observerController.jumpTo 翻页把目标拉进可视区(异步逐步翻页),
  ///    [sliverContext] 指定目标所在的 sliver(活跃/历史);
  /// 2. Scrollable.ensureVisible 精确对齐到视口 30% 处,
  ///    消除 jumpTo 的 alignment 漂移。
  ///
  /// 短列表场景自动 clamp 不会越界。
  Future<void> scrollToMessageIndex(
    int index,
    String messageId, {
    BuildContext? sliverContext,
  }) async {
    final observer = _ctx.getObserverController();
    if (observer.sliverContexts.isEmpty) {
      // sliverContexts 未就绪,等一帧再试
      await WidgetsBinding.instance.endOfFrame;
      if (observer.sliverContexts.isEmpty) return;
    }
    if (sliverContext != null && !sliverContext.mounted) return;
    await observer.jumpTo(
      index: index,
      alignment: 0.3,
      sliverContext: sliverContext,
    );
    if (!_ctx.isMounted()) return;
    // jumpTo 完成后 target 必然已渲染,从 bubbleKeys 拿 ctx 做 ensureVisible 兜底
    final ctx = _ctx.getBubbleKeys()[messageId]?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(
      ctx,
      alignment: 0.3,
      duration: Duration.zero,
      curve: Curves.easeOut,
    );
  }

  /// 跳转到被引用的消息。三条路径:
  /// 1. **本地命中**:先查活跃 sliver(liveMessages),再查历史 sliver
  ///    (historyMessages) → 在对应 sliver 内滚动 + 1s 高亮 flash;
  /// 2. **本地未命中**:调 api.getMessageContext 拉 target + 前后 N 条上下文 →
  ///    ChatProvider.mergeJumpedContext 合并(消息进 historyMessages)→
  ///    在历史 sliver 内找新 index 滚动 + 高亮;
  ///    - target 已撤回 / 不存在(server 404):提示「原消息已删除」;
  ///    - 无权限(forbidden):提示「无权查看此消息」;
  ///    - 其他错误:提示「跳转失败」。
  Future<void> jumpToMessage(String messageId) async {
    final chatState = _ctx.ref.read(chatProvider(_ctx.chatKey));

    final liveIdx = chatState.liveMessages.indexWhere((m) => m.id == messageId);
    if (liveIdx >= 0) {
      await scrollToMessageIndex(
        liveIdx + 1,
        messageId,
        sliverContext: _ctx.getLiveSliverContext(),
      );
      highlightMessage(messageId);
      return;
    }

    final histIdx =
        chatState.historyMessages.indexWhere((m) => m.id == messageId);
    if (histIdx >= 0) {
      await scrollToMessageIndex(
        histIdx,
        messageId,
        sliverContext: _ctx.getHistorySliverContext(),
      );
      highlightMessage(messageId);
      return;
    }

    // 本地未命中:提示条 → 调 API → 合并 → 找新 index → 滚动 + 高亮
    showAppSnackBar(_ctx.getContext(), '正在跳转...');

    try {
      final ApiService api = _ctx.ref.read(apiProvider);
      final MessageContext ctx = await api.getMessageContext(messageId);

      if (!_ctx.isMounted()) return;
      _ctx.ref.read(chatProvider(_ctx.chatKey).notifier).mergeJumpedContext(ctx);

      // mergeJumpedContext 是同步更新,但 widget rebuild 在下一帧。
      // 等 endOfFrame 再读新 historyMessages,确保 indexWhere 拿到合并后的列表。
      await WidgetsBinding.instance.endOfFrame;

      final newIdx = _ctx.ref
          .read(chatProvider(_ctx.chatKey))
          .historyMessages
          .indexWhere((m) => m.id == messageId);
      if (newIdx < 0) {
        // 合并后仍找不到(理论不发生:target 必然进列表),静默返回
        return;
      }
      await scrollToMessageIndex(
        newIdx,
        messageId,
        sliverContext: _ctx.getHistorySliverContext(),
      );
      highlightMessage(messageId);
    } on MessageNotFoundException {
      if (!_ctx.isMounted()) return;
      // server 返 404:target 不存在 / 已撤回 / 已被当前 user 隐藏(hide)。
      // 用通用文案「已删除」覆盖多种场景。
      showAppSnackBar(_ctx.getContext(), '原消息已删除', type: SnackBarType.error);
    } on NoAccessException {
      if (!_ctx.isMounted()) return;
      showAppSnackBar(_ctx.getContext(), '无权查看此消息', type: SnackBarType.error);
    } catch (e) {
      if (!_ctx.isMounted()) return;
      showAppSnackBar(_ctx.getContext(), '跳转失败: $e', type: SnackBarType.error);
    }
  }

  /// 滚到底部(最新消息端)。目标 px 由 [dualSliverBottomTarget] 计算:
  /// live 非空 → maxScrollExtent;live 空 → max(minScrollExtent, -vd)。
  ///
  /// 已在底部(|target - px| <= 5)时跳过动画,消除「已到底还要 animateTo」
  /// 造成的抖动。
  ///
  /// 修复「发送新消息后不跳到底部」:postFrame 时刻 SliverList 懒加载下,
  /// 新消息(高卡片/大图/超长 markdown > cacheExtent)可能尚未布局,
  /// maxScrollExtent 未包含其高度 → target≈px → 第一次即提前 return,
  /// 之后无任何代码再触发滚动。这里在首次 animateTo 发起后调度**一次**
  /// postFrame 校准:新内容布局后重算 target,若仍未到底再滚一次。
  ///
  /// 注意:校准**只做一次**(单次 postFrame,不递归),避免 agent 流式回复持续
  /// 增长 maxScrollExtent 时陷入无限滚动循环。流式场景由 streamer 的
  /// 流式跟随(jumpTo 实时底部)接管,这里只兜底一次性大高度内容漏滚。
  void scrollToBottom() {
    final scrollCtrl = _ctx.getScrollCtrl();
    if (!scrollCtrl.hasClients) return;
    final target = dualSliverBottomTarget(
      minScrollExtent: scrollCtrl.position.minScrollExtent,
      maxScrollExtent: scrollCtrl.position.maxScrollExtent,
      viewportDimension: scrollCtrl.position.viewportDimension,
      liveEmpty: _ctx.getLiveEmpty(),
    );
    if ((target - scrollCtrl.position.pixels).abs() <= 5) return;
    scrollCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    ).then((_) {
      // 一次性校准(不递归,无循环):首次动画期间新内容(大高度卡片)可能才被
      // SliverList 布局、maxScrollExtent 增长 → 若仍未到底再滚一次即停。
      // 流式增长由 streamer 流式跟随接管,这里不重复追。
      if (!_ctx.isMounted()) return;
      if (!scrollCtrl.hasClients) return;
      final newTarget = dualSliverBottomTarget(
        minScrollExtent: scrollCtrl.position.minScrollExtent,
        maxScrollExtent: scrollCtrl.position.maxScrollExtent,
        viewportDimension: scrollCtrl.position.viewportDimension,
        liveEmpty: _ctx.getLiveEmpty(),
      );
      if ((newTarget - scrollCtrl.position.pixels).abs() > 5) {
        scrollCtrl.animateTo(
          newTarget,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 释放高亮 Timer,避免页面退出后 setState-after-dispose。
  void dispose() {
    _highlightTimer?.cancel();
  }
}
