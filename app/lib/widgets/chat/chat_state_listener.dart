import 'dart:async';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/agent_sessions_provider.dart' show AgentSessionsNotifier;
import '../../providers/chat_provider.dart' show ChatNotifier, chatProvider;
import '../../providers/chat_state.dart' show ChatState;
import '../../providers/conversation_provider.dart' show conversationProvider;
import 'conv_sync_controller.dart' show ConvSyncController;
import 'jump_controller.dart' show JumpController, dualSliverBottomTarget;
import 'unread_locator_controller.dart' show UnreadLocatorController;

/// [ChatStateListener] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次,把所有外部依赖打包传入,listener
/// 内部通过 `_ctx.xxx` 访问,实现解耦 + 可测试性。
@immutable
class ChatStateListenerContext {
  /// for conversationProvider / chatProvider.read。
  final WidgetRef ref;

  /// 当前会话 id(markRead / syncUnread 目标)。
  final String convId;

  /// agent_id(null:user-user DM 会话无 agent)。
  final String? agentId;

  /// chatProvider family key(convId + agentId)。
  final ({String convId, String? agentId}) chatKey;

  /// 替代 widget.mounted(dispose 后不再读 ref / 调度 timer 回调)。
  final bool Function() isMounted;

  /// 替代 setState(触发 rebuild 让 overlay / pendingScroll 生效)。
  final void Function(VoidCallback) onSetState;

  /// 用户是否主动滚动离开底部(拖动/惯性使 px 离开底部 50px 容差)。
  ///
  /// 替代 isAtBottom 作为「贴底跟随」的判定条件:大高度非流式消息(审批卡片)插入
  /// 时 maxScrollExtent 跳增但 px 不变,isAtBottom 不会更新;而 (2) 分支调度的
  /// scrollToBottom 动画又会让 isAtBottom 在动画窗口内翻 false,导致流式跟随
  /// 失效。只有用户主动滚动离开才应停止跟随,被动被新内容顶出不视为离开。
  final bool Function() getUserScrolledAway;

  /// 滚动控制器(流式跟随读 maxScrollExtent / hasClients)。
  final ScrollController Function() getScrollCtrl;

  /// chatProvider notifier(incrementUnread 等)。
  final ChatNotifier Function() getNotifier;

  /// agent_session 的 sessions notifier(可 null:user-user DM 会话无 agent)。
  final AgentSessionsNotifier? Function() getSessionsNotifier;

  /// 跳转/滚到底控制器(在底部 + 对方新消息时滚到底)。
  final JumpController Function() getJumpController;

  /// 会话已读同步控制器(在底部 + 对方新消息时 markRead)。
  final ConvSyncController Function() getConvSync;

  /// 未读定位控制器(firstUnread 首次设置时 jumpTo 定位)。
  final UnreadLocatorController Function() getUnreadLocator;

  /// 合并偏移量刷新(打字态 + loadMore 指示器)。
  final VoidCallback onRefreshExtraItems;

  const ChatStateListenerContext({
    required this.ref,
    required this.convId,
    required this.agentId,
    required this.chatKey,
    required this.isMounted,
    required this.onSetState,
    required this.getUserScrolledAway,
    required this.getScrollCtrl,
    required this.getNotifier,
    required this.getSessionsNotifier,
    required this.getJumpController,
    required this.getConvSync,
    required this.getUnreadLocator,
    required this.onRefreshExtraItems,
  });
}

/// 聊天状态变化副作用监听器(方案 A:Controller class + 依赖注入)。
///
/// 封装 chat_page build 中 ref.listen(chatProvider) 的回调(~186 行),处理 4 类副作用:
/// - (0) init load 未读同步(isInitialLoading true→false + server unread=0 时刷 list 徽章)
/// - loadMore overlay 显示控制(开始即显 / 完成后延迟 300ms 隐藏)
/// - (1) 未读定位(firstUnreadMessageId null→非null,_didLocateUnread 守卫防重复)
/// - (2) messages 增长(prepend vs append,按「用户是否主动离开底部」决定滚底/增计数)
/// - (3) 回显消息 pendingScroll(自己 echo 后滚到底看自己消息)
///
/// 贴底跟随条件用 getUserScrolledAway 而非 isAtBottom:卡片等大高度消息插入使
/// maxScrollExtent 跳增但 px 不变,isAtBottom 不会及时更新;scrollToBottom 动画又
/// 会临时翻 false 导致流式跟随失效。用户主动滚动离开底部才停止跟随。
///
/// chat_page 在 initState 创建(在所有被依赖的 controller 之后),dispose 时
/// cancel loadMore 隐藏 timer(避免 setState-after-dispose)。
class ChatStateListener {
  final ChatStateListenerContext _ctx;

  ChatStateListener(this._ctx);

  /// 防止未读定位重复触发:_initialize 成功置位 firstUnreadMessageId 后只定位一次。
  bool _didLocateUnread = false;
  bool get didLocateUnread => _didLocateUnread;

  /// loadMore overlay 显示控制。
  /// isLoadingMore=true 期间 + 完成后延迟 300ms 内为 true,让用户一定看到反馈。
  /// 直接用 chatState.isLoadingMore 会因 loadMore 太快(100 条 < 200ms)用户看不到。
  Timer? _loadingHideTimer;
  bool get loadingHideTimerActive => _loadingHideTimer != null;

  /// 卡片 AnimatedSize 平滑增高期间的持续跟随 timer。
  /// 见 [_startCardHeightFollow]。dispose 时 cancel,避免页面退出后 setState。
  Timer? _cardFollowTimer;

  /// 自己消息 echo 后滚到底(pendingScroll 在 build 消费)。
  bool _pendingScroll = false;
  bool get pendingScroll => _pendingScroll;
  set pendingScroll(bool v) => _pendingScroll = v;

  /// 首屏初始化完成(isInitialLoading: true→false)且无未读定位需求时,
  /// 在 build 消费一次 jumpTo(maxScrollExtent) 兜底定位到最新消息。
  ///
  /// 双 sliver center 几何下,初始 pixels=0 落在空锚点(center sliver 起点),
  /// 而非最新消息;若不兜底,进入既有会话首屏可能停在空白或过卷位置。
  bool _pendingInitialScroll = false;
  bool get pendingInitialScroll => _pendingInitialScroll;
  set pendingInitialScroll(bool v) => _pendingInitialScroll = v;

  /// ref.listen(chatProvider) 回调:从 chat_page build 原样搬入,只替换依赖注入访问。
  ///
  /// 改动规则:
  /// - `mounted` → `_ctx.isMounted()`
  /// - `setState(() {})` → `_ctx.onSetState(() {})`
  /// - `_userScrolledAway` → `_ctx.getUserScrolledAway()`(替代原 _isAtBottom 判定跟随)
  /// - `_notifier` → `_ctx.getNotifier()`
  /// - `_sessionsNotifier?` → `_ctx.getSessionsNotifier()?`
  /// - `_jumpController` → `_ctx.getJumpController()`
  /// - `_convSync` → `_ctx.getConvSync()`
  /// - `_unreadLocator` → `_ctx.getUnreadLocator()`
  /// - `_refreshExtraItems()` → `_ctx.onRefreshExtraItems()`
  /// - `widget.convId` → `_ctx.convId`
  /// - `ref.read(...)` → `_ctx.ref.read(...)`
  void onChatStateChanged(ChatState? prev, ChatState next) {
    debugPrint(
      '[listen] prev: messages=${prev?.displayMessages.length}, '
      'firstUnread=${prev?.firstUnreadMessageId}, hasMore=${prev?.hasMore}; '
      'next: messages=${next.displayMessages.length}, '
      'firstUnread=${next.firstUnreadMessageId}, hasMore=${next.hasMore}',
    );

    // chatProvider 拿到 server 真值 unread=0 时,同步清 conversation[X].unreadCount。
    // 修复"上次 markReadAtBottom 漏同步导致 list 徽章残留 N,本次进入 server 已 0
    // 但 list 还是 N"的历史数据不一致问题。仅在 _initialize 完成瞬间触发一次
    // (isInitialLoading: true→false),避免每次 state 变化都重复刷。
    if (prev?.isInitialLoading == true && !next.isInitialLoading) {
      if (next.unreadCount == 0 && next.firstUnreadMessageId == null) {
        debugPrint(
          '[debug-initLoad] server unread=0 convId=${_ctx.convId} '
          'syncing conversationProvider',
        );
        _ctx.ref
            .read(conversationProvider.notifier)
            .setUnreadCountLocally(_ctx.convId, 0);
        _ctx.getSessionsNotifier()?.setUnreadCountLocally(_ctx.convId, 0);
      }
    }

    // pendingInitialScroll 等 server _initialize 完成(getConversation +
    // getUnreadInfo + getMessages 全 done)再触发。DB eager hit(F4)只设
    // isInitialLoading=false 即时呈现消息,但 convType/sessionMeta 此时尚未
    // 就绪,底部输入区(含 agent_session 的 strip)未挂载,Expanded 扣除高度
    // 不含 strip → 过早 jumpTo 会让最新消息被后续挂载的 strip 遮挡。
    if (prev?.isServerInitialized == false && next.isServerInitialized) {
      if (next.firstUnreadMessageId == null) {
        debugPrint(
          '[listen] (init) schedule initial jumpTo bottom '
          '(server initialized, no unread locator)',
        );
        _pendingInitialScroll = true;
      }
    }

    // loadMore overlay 显示控制：开始加载立刻显示，完成后延迟 300ms 隐藏。
    // 直接绑定 chatState.isLoadingMore 会因 loadMore 太快用户看不到。
    if (prev?.isLoadingMore == false && next.isLoadingMore) {
      _loadingHideTimer?.cancel();
      _loadingHideTimer = null;
      _ctx.onSetState(() {}); // 触发重建显示 overlay
    } else if (prev?.isLoadingMore == true && !next.isLoadingMore) {
      final timer = Timer(const Duration(milliseconds: 300), () {
        if (_ctx.isMounted()) {
          _loadingHideTimer = null;
          _ctx.onSetState(() {});
        }
      });
      _loadingHideTimer = timer;
      _ctx.onSetState(() {});
    }

    // (0) 进入会话不再立即 markRead：上滑阅读进度只本地递减，server 保留初始未读。
    // 仅在用户真正到达底部（_isAtBottom）或点浮标跳底部时才同步 server。
    // 修复「退出重进丢失剩余未读」bug：原逻辑进入即清 server，重进看不到剩余 N 条。

    // (1) 未读定位
    final prevFirstUnread = prev?.firstUnreadMessageId;
    if (prevFirstUnread == null &&
        next.firstUnreadMessageId != null &&
        !_didLocateUnread) {
      _didLocateUnread = true;
      debugPrint('[listen] (1) locateUnread TRIGGERED, scheduling');
      final firstUnread = next.firstUnreadMessageId!;
      final msgs = next.displayMessages;
      final firstUnreadIdx = msgs.indexWhere((m) => m.id == firstUnread);
      final firstIsUnread =
          msgs.isNotEmpty && msgs.first.id == firstUnread;
      // markRead 触发条件(短列表/用户已在底部场景,绕过 _onScroll 的 false→true 检测):
      //   (A) firstUnread 就是 messages.first(最新一条):用户已在底部,无可上滑的未读
      //   (B) messages 为空:server 返的未读消息全被 _filterDisplayable 过滤(如 step_finish),
      //       用户无可读内容,徽章应立即清零(server FirstUnread 跳过 silent 是根治,
      //       此处是 client 防御性兜底,防 server 旧数据 / 未来类似场景)
      //   (C) firstUnreadIdx < 0:server 返了 firstUnread 但 client 列表里找不到,
      //       定位无法生效,徽章应立即清零
      if (firstIsUnread || msgs.isEmpty || firstUnreadIdx < 0) {
        debugPrint(
          '[listen] (1) immediate markRead '
          '(firstIsUnread=$firstIsUnread, msgsEmpty=${msgs.isEmpty}, '
          'idx=$firstUnreadIdx) convId=${_ctx.convId}',
        );
        _ctx.getConvSync().markRead();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_ctx.isMounted()) {
          _ctx.getUnreadLocator().scrollToFirstUnreadIfNeeded();
        }
      });
    } else if (prevFirstUnread == null &&
        next.firstUnreadMessageId != null &&
        _didLocateUnread) {
      debugPrint(
        '[listen] (1) locateUnread already done (_didLocateUnread=true)',
      );
    }

    // (2) messages 增长：区分「新消息 prepend 头部」vs「loadMore append 末尾」
    // 双 sliver center 几何下:
    // - 新消息 prepend(进活跃 sliver trailing 端):只增大 maxScrollExtent,
    //   不影响已有 item 的 offset → 视口天然稳定,无需 standby 保持锚点。
    // - loadMore append(进历史 sliver leading 端):只减小 minScrollExtent,
    //   px 不变 → firstUnread 视觉位置自动保持。
    final oldLen = prev?.displayMessages.length ?? 0;
    final newLen = next.displayMessages.length;
    if (newLen > oldLen && oldLen > 0) {
      final isPrepend =
          prev!.displayMessages.first.id != next.displayMessages.first.id;
      if (isPrepend) {
        final changeCount = newLen - oldLen;
        final isSelfEcho = next.displayMessages.first.senderType == 'user';
        debugPrint(
          '[listen] (2) newMsg prepend $oldLen→$newLen, '
          'userScrolledAway=${_ctx.getUserScrolledAway()}, '
          'changeCount=$changeCount, '
          'isSelfEcho=$isSelfEcho',
        );
        if (_ctx.getUnreadLocator().isLocating) {
          // 定位期间跳过 prepend 所有滚动/计数副作用,避免抢占 scrollCtrl
          // (未读 jumpTo 翻页不收敛→onLocateComplete 拖到 5s 兜底) 和污染
          // 未读状态(markRead / incrementUnread)。定位完成后 onLocateComplete
          // → checkUnreadSeen 会重新评估视口内未读。
          // 注意:不能只守卫「滚底+markRead」分支,否则 isLocating=true 会
          // fall through 到 else 增计数,误把"用户在底部定位中"当成"不在底部"。
          debugPrint('[listen] (2) skip prepend during unread locating');
        } else if (isSelfEcho) {
          // 自己发消息的 echo：交给 (3) 分支滚到底看自己消息，不增计数（自己发的不算新消息）
        } else if (!_ctx.getUserScrolledAway()) {
          // 未主动离开底部（含被卡片等大高度消息被动顶出）：滚到底让新消息可见。
          // 不能用 getIsAtBottom：卡片插入后 maxScrollExtent 跳增但 px 不变,
          // isAtBottom 保持旧值;随后 scrollToBottom 动画又会临时翻 false,导致
          // 该分支与流式跟随双双失效。用「用户主动滚动离开」标志判定更稳。
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _ctx.getJumpController().scrollToBottom(),
          );
          _ctx.getConvSync().markRead();
        } else {
          // 不在底部 + 对方新消息：双 sliver center 几何下新消息进活跃 sliver
          // trailing 端,只增大 maxScrollExtent,已有 item offset 不变,视口天然
          // 稳定(无需 standby)。仅增加未读计数(统一未读浮标提示)。
          // silent 消息(过程类:AI 思考、工具调用、step_finish 等)不增未读浮标,
          // 与 server IncrUnreadTx + bg-service + conversationProvider
          // + agentSessionsProvider 四路完全对齐,否则用户在 ChatPage 内会看到
          // 浮标 N 但 server unread=0 的不一致。
          final newMsg = next.displayMessages.first;
          final isSilent = newMsg.content['silent'] == true;
          if (!isSilent) {
            _ctx.getNotifier().incrementUnread();
            // 同步会话列表徽章：conversationProvider 内置 _onMessageCreate 在
            // isActive=true 时不 +1（与 server 对齐），但浮标 +1 了，这里手动同步
            // 让两端一致，否则返回列表时徽章比浮标少。
            _ctx.ref
                .read(conversationProvider.notifier)
                .incrementUnreadLocally(_ctx.convId);
          }
        }
      } else {
        debugPrint(
          '[listen] (2) loadMore append $oldLen→$newLen, '
          'history sliver extends leading (center keeps px)',
        );
      }
    }

    // (2.6) 流式占位→终态替换补 markRead(修复 server 未读残留):
    // STREAM(op=14) 占位插入时 (2) 分支触发的 markRead 发生在 server 落库之前
    // (MarkRead 取未读为 0,无实际效果);终态 MESSAGE_CREATE 落库(server IncrUnread +1)
    // 后 app 同位置替换占位、displayMessages 长度不变,(2) 分支 newLen>oldLen 不成立
    // → 不再 markRead,server 端未读逐条累积。实时贴底观看后返回列表刷新会看到残留未读。
    // 这里检测「占位被终态替换」,贴底时补 markRead 对齐;已滚动离开时保持未读浮标不动。
    if (_hasStreamPlaceholderReplaced(prev, next) &&
        !_ctx.getUserScrolledAway() &&
        !_ctx.getUnreadLocator().isLocating) {
      debugPrint(
        '[listen] (2.6) stream placeholder → terminal replace, markRead convId=${_ctx.convId}',
      );
      _ctx.getConvSync().markRead();
    }

    // (2.5) 非流式消息 content 更新(卡片 running→PATCH 回写内容增高):
    // 不增加消息条数,(2) 分支不触发;无流式共存时流式跟随也不触发 → px 停在
    // 旧底部、位置失真,后续任何跟随动作一次大跳(抖动)。卡片渲染用 AnimatedSize
    // 平滑增高(250ms),高度是渐进变化 → 一次性 scrollToBottom 目标会随动画增长
    // 而过时。改用周期 jumpTo 实时底部,直到卡片展开完成或用户离开。
    final contentChanged = _hasNonStreamingContentChange(prev, next);
    if (contentChanged &&
        !_ctx.getUserScrolledAway() &&
        !_ctx.getUnreadLocator().isLocating) {
      // isLocating 守卫：未读定位 jumpTo 翻页期间不抢占 scrollCtrl（同 (2)
      // / 流式跟随），避免翻页不收敛。详见 (2) 分支注释。
      _startCardHeightFollow();
    }

    // 流式跟随：仅用户未主动离开底部时贴住实时底部。
    // 不能用 getIsAtBottom：卡片插入后 scrollToBottom 动画窗口内 isAtBottom 为
    // false,会导致流式文本刚展开就停止跟随(永久失效)。
    // isLocating 守卫：未读定位 jumpTo 翻页窗口期不抢占 scrollCtrl（同 (2) /
    // (2.5)），避免翻页不收敛、onLocateComplete 拖到 5s 兜底。
    if (!_ctx.getUserScrolledAway() &&
        !_ctx.getUnreadLocator().isLocating &&
        next.liveMessages.any((m) => m.isStreaming)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final scrollCtrl = _ctx.getScrollCtrl();
        if (_ctx.isMounted() &&
            scrollCtrl.hasClients &&
            !_ctx.getUserScrolledAway()) {
          final pos = scrollCtrl.position;
          scrollCtrl.jumpTo(dualSliverBottomTarget(
            minScrollExtent: pos.minScrollExtent,
            maxScrollExtent: pos.maxScrollExtent,
            viewportDimension: pos.viewportDimension,
            liveEmpty: next.liveMessages.isEmpty,
          ));
        }
      });
    }

    // (3) 处理回显消息（自己发的消息到达后滚到底，让用户看到自己刚发的消息）。
    // 关键约束 1：仅「定位未完成」时跳过——(1) jumpTo 只在 firstUnread 首次设置时
    //   触发一次（_didLocateUnread 守卫），定位完成后即使 firstUnread 仍在 state 里
    //   （用户没滚到底清除），自己 echo 也应该滚到底看自己消息。
    // 关键约束 2：仅「自己 echo」（senderType=user）才触发——对方发的新消息
    //   由 (2) 分支按 _isAtBottom 处理（在底部滚/不在底部增计数），不能在这里误滚到底。
    if (next.displayMessages.isEmpty) {
      debugPrint('[listen] (3) skip pendingScroll: messages empty');
      return;
    }
    if (!_didLocateUnread && next.firstUnreadMessageId != null) {
      debugPrint('[listen] (3) skip pendingScroll: still locating');
      return; // 定位进行中：让 (1) 的 jumpTo 生效
    }
    if (next.displayMessages.first.senderType != 'user') {
      debugPrint(
        '[listen] (3) skip pendingScroll: not self echo '
        '(senderType=${next.displayMessages.first.senderType})',
      );
      return; // 对方新消息：由 (2) 分支处理
    }
    final prevFirstId = prev?.displayMessages.isEmpty == true
        ? null
        : prev?.displayMessages.first.id;
    debugPrint(
      '[debug-pendingScroll] (3) check: prevFirstId=$prevFirstId '
      'nextFirstId=${next.displayMessages.first.id} '
      'senderType=${next.displayMessages.first.senderType}',
    );
    if (prevFirstId != next.displayMessages.first.id) {
      debugPrint(
        '[debug-pendingScroll] SET pendingScroll=true (id changed)',
      );
      _pendingScroll = true;
    }
    _ctx.onRefreshExtraItems();
  }

  /// 检测「流式占位(stream:xxx)被终态 MESSAGE_CREATE 同位置替换」。
  ///
  /// 特征:prev 有 `stream:` 前缀 id 且 next 消失 + next 出现新的非 stream server id
  /// + displayMessages 总长度不变(替换不新增行)。用于 (2.6) 分支在实时贴底观看时
  /// 补 markRead,把 server 端终态落库产生的未读及时清零。
  bool _hasStreamPlaceholderReplaced(ChatState? prev, ChatState next) {
    if (prev == null) return false;
    if (prev.displayMessages.length != next.displayMessages.length) return false;
    final prevIds = prev.displayMessages.map((m) => m.id).toSet();
    final nextIds = next.displayMessages.map((m) => m.id).toSet();
    final placeholderGone = prev.displayMessages
        .any((m) => m.id.startsWith('stream:') && !nextIds.contains(m.id));
    final terminalAdded = next.displayMessages
        .any((m) => !m.id.startsWith('stream:') && !prevIds.contains(m.id));
    return placeholderGone && terminalAdded;
  }

  /// 是否发生非流式消息的 content 更新(如卡片 PATCH 增高)。
  /// 流式消息的增量更新由流式跟随分支处理,不在此列;仅比较 liveMessages 中
  /// 非流式消息的 content 是否变化(同 id 对比)。
  bool _hasNonStreamingContentChange(ChatState? prev, ChatState next) {
    if (prev == null) return false;
    final prevById = {for (final m in prev.liveMessages) m.id: m};
    return next.liveMessages.any((m) {
      if (m.isStreaming) return false;
      final pm = prevById[m.id];
      // 注意:不能用 mapEquals —— 它做浅比较(content['data'] 是独立 map
      // 实例时恒不相等 → 误判 contentChanged=true,每次更新都启动卡片跟随)。
      return pm != null && !_deepEquals(pm.content, m.content);
    });
  }

  /// 深度比较两个 JSON 值(嵌套 Map/List/标量)。用于 content 变化检测。
  static bool _deepEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_deepEquals(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  /// 卡片 AnimatedSize 平滑增高(250ms 渐进变化)期间持续贴底跟随。
  ///
  /// 卡片高度是渐进增长的,一次性 scrollToBottom(animateTo) 目标会随动画增长而
  /// 过时 → 展开完成视口落后。这里用 16ms 周期 jumpTo 实时底部,让视口与卡片
  /// 展开同步平滑;卡片展开完成(320ms 兜底,略大于 250ms 动画)或用户主动滚动
  /// 离开后停止。
  void _startCardHeightFollow() {
    _cardFollowTimer?.cancel();
    var elapsedMs = 0;
    _cardFollowTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      elapsedMs += 16;
      final stop = elapsedMs >= 320 ||
          !_ctx.isMounted() ||
          _ctx.getUserScrolledAway();
      if (stop) {
        t.cancel();
        _cardFollowTimer = null;
        return;
      }
      final scrollCtrl = _ctx.getScrollCtrl();
      if (!scrollCtrl.hasClients) return;
      final pos = scrollCtrl.position;
      final liveEmpty = _ctx.ref
          .read(chatProvider(_ctx.chatKey))
          .liveMessages
          .isEmpty;
      scrollCtrl.jumpTo(dualSliverBottomTarget(
        minScrollExtent: pos.minScrollExtent,
        maxScrollExtent: pos.maxScrollExtent,
        viewportDimension: pos.viewportDimension,
        liveEmpty: liveEmpty,
      ));
    });
  }

  /// cancel loadMore 隐藏 timer,避免页面退出后 timer fire 触发 setState-after-dispose。
  void dispose() {
    _loadingHideTimer?.cancel();
    _cardFollowTimer?.cancel();
  }
}
