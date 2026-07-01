import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scrollview_observer/scrollview_observer.dart';
import 'package:file_picker/file_picker.dart';
import '../models/agent.dart' show AgentStatus;
import '../models/message.dart' show ChatMessage;
import '../models/msg_type.dart';
import '../models/ws_message.dart' show WSMessage;
import '../providers/agent_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart'
    show ChatNotifier, chatProvider, wsProvider;
import '../providers/conversation_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/typing_provider.dart';
import '../services/websocket_service.dart';
import '../utils/gallery_image.dart' show collectConversationImages;
import '../utils/snackbar.dart';
import '../widgets/message_bubble.dart' show MessageBubble, formatTimestamp;
import '../widgets/message_context_menu.dart';
import '../widgets/gallery/zoomable_gallery.dart' show ZoomableGallery;
import '../widgets/message_input_bar.dart';
import '../widgets/avatar_picker.dart' show defaultAssetPickerConfig;
import '../widgets/feedback/app_dialog.dart';
import '../widgets/load_more_indicator.dart';
import '../widgets/typing_bubble.dart';
import '../widgets/unread_nav_badge.dart';
import '../widgets/jump_to_bottom_button.dart';
import '../widgets/unread_separator.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';

const _imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp'};

/// 计算当前视口内新进入的未读消息 id 列表。
///
/// 提取为顶层 pure function 便于 unit test 直接驱动（避免依赖 ScrollController / viewport）。
/// 由 _ChatPageState._checkUnreadSeen 调用，语义保持一致。
///
/// 三个过滤维度：
///   1. msg.isRead == false（server 端 user 自发落地 TRUE，故 user 消息自动跳过）
///   2. 不在 seenUnreadMsgIds 内（已计入过的不再重复 decrement）
///   3. isInViewport(msg.id) == true（由调用方注入 viewport 检查函数）
@visibleForTesting
List<String> computeNewlySeenUnread({
  required List<ChatMessage> messages,
  required int firstUnreadIdx,
  required Set<String> seenUnreadMsgIds,
  required bool Function(String messageId) isInViewport,
}) {
  final newlySeen = <String>[];
  for (var i = 0; i <= firstUnreadIdx; i++) {
    final msg = messages[i];
    // 过滤口径：只看 isRead 单一字段。
    // server 端 createMessage 对 user 发的消息落地 is_read=TRUE（自己发的不计未读），
    // 故 client 不再需要 senderType 兜底。参与者模型重构后，client 这层逻辑天然兼容
    // （只看字段不看角色）。
    if (msg.isRead) continue;
    if (seenUnreadMsgIds.contains(msg.id)) continue;
    if (isInViewport(msg.id)) newlySeen.add(msg.id);
  }
  return newlySeen;
}

/// 聊天页：入参为 convId + agentId。
///
/// 设计要点：
/// - convId 直接由路由传入，无需 _initConversation 异步拉取 findOrCreate。
///   调用方（MessagesPage / AgentListPage / AgentDetailPage）负责在跳转前
///   确保 conversation 已建，并把 convId 通过 path 参数、agentId 通过 query 传入。
/// - agent 名字从 agentListProvider 兜底查找（不依赖 conversationProvider，
///   因为新建会话可能尚未进入消息列表）。
/// - AppBar subtitle 根据 typingProvider / agent.status 显示"对方正在输入..."/在线/离线。
/// - ListView 顶部插入 TypingBubble 占位 index 0，与 typingProvider 联动。
///
/// 多选模式（长按消息菜单进入）：
/// - _selectionMode 控制 AppBar/底部栏/勾选框切换
/// - _selectedIds 记录勾选的消息 id
/// - 长按消息弹 MessageContextMenu(OverlayEntry + LayerLink 紧贴气泡)
class ChatPage extends ConsumerStatefulWidget {
  final String convId;
  final String agentId;

  const ChatPage({super.key, required this.convId, required this.agentId});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _scrollCtrl = ScrollController();
  bool _pendingScroll = false;

  // scrollview_observer：位置保持 + index 滚动
  late final ListObserverController _observerController;
  late final ChatScrollObserver _chatObserver;

  /// 已「进入过视口」的未读消息 id（防重复减）。
  /// 由 _checkUnreadSeen 维护：每次滚动检测新增的「刚进入视口」的未读，
  /// 加入此集合并 decrementUnread(N)。
  final Set<String> _seenUnreadMsgIds = {};

  /// 防止未读定位重复触发：_initialize 成功置位 firstUnreadMessageId 后只定位一次。
  bool _didLocateUnread = false;

  /// jumpTo 定位未读期间为 true，期间禁用 _onScroll 触发的 loadMore。
  ///
  /// jumpTo 把 px 跳到接近 maxScrollExtent 处（firstUnread 是视觉顶部），
  /// 若不拦截 _onScroll 会把"px 接近顶部"当成"用户上滑加载历史"，触发 loadMore。
  /// loadMore 的 pixels 校正又把 px 推到更顶，循环加载直到 hasMore=false，
  /// 把 firstUnread 推到列表中段（messages 累积成几十条），完全脱离定位意图。
  bool _isLocating = false;

  /// 滚动位置跟踪：是否在底部（pixels <= 50）
  bool _isAtBottom = true;

  /// loadMore overlay 显示控制。
  /// isLoadingMore=true 期间 + 完成后延迟 300ms 内为 true，让用户一定看到反馈。
  /// 直接用 chatState.isLoadingMore 会因 loadMore 太快（100 条 < 200ms）用户看不到。
  Timer? _loadingHideTimer;

  /// markMessagesRead 同步 debounce。
  /// 用户上滑阅读未读时本地 unreadCount 即时减少，但 server 同步 debounce 500ms,
  /// 避免 fling 期间频繁打 server。dispose 时若 timer pending 立即 flush 兜底。
  Timer? _markReadDebounce;

  /// 待同步给 server 的已读 message id 集合（debounce 期间累积）。
  /// timer fire 时一次性 flush，清空集合。
  final Set<String> _pendingReadMsgIds = {};

  /// 多选模式状态。
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  /// 长按菜单 Overlay。同一时间最多一个菜单。
  OverlayEntry? _menuEntry;

  /// 每条消息对应一个 GlobalKey,用于拿 RenderObject 算菜单定位/出屏判定。
  final Map<String, GlobalKey> _bubbleKeys = {};

  /// 当前长按选择态的消息 id（菜单关闭时清）。
  String? _activeSelectMsgId;

  /// 当前菜单的定位缓存（滚动时比较，变化才重建 OverlayEntry）。
  _MenuPlacement? _menuPlacement;

  /// 选区文本缓存（SelectableRegion.onSelectionChanged 收集，供复制读取）。
  String? _selectedText;

  /// 常驻 SelectableRegion 的 key（包整个消息列表，统一选择区）。
  final GlobalKey<SelectableRegionState> _selectionKey =
      GlobalKey<SelectableRegionState>();

  /// 常驻 SelectableRegion 的 focusNode（持久持有，dispose 释放）。
  final FocusNode _selectionFocusNode = FocusNode();

  /// ListView 的 key，用于拿它的 RenderBox 算可见区域
  /// （已扣除 AppBar 和输入栏，菜单定位/出屏判定用它而非全屏）。
  final GlobalKey _listViewKey = GlobalKey();

  /// 订阅 MESSAGE_CREATE：agent 回复到达时清掉 typing。
  StreamSubscription<WSMessage>? _msgSub;

  /// 缓存 dispose 阶段需要的 notifier / ws 引用。
  late final ConversationListNotifier _convNotifier;
  late final TypingNotifier _typingNotifier;
  late final WebSocketService _ws;

  @override
  void initState() {
    super.initState();
    debugPrint('[chatPage] initState convId=${widget.convId} agentId=${widget.agentId}');
    // scrollview_observer 初始化。
    // ChatScrollObserver 构造是位置参数（observerController），不是命名参数。
    _observerController = ListObserverController(controller: _scrollCtrl)
      ..cacheJumpIndexOffset = false; // IM 经常增删消息，关闭偏移缓存
    _chatObserver = ChatScrollObserver(_observerController)
      ..fixedPositionOffset = 5
      ..toRebuildScrollViewCallback = () {
        if (mounted) setState(() {});
      };
    _scrollCtrl.addListener(_onScroll);
    _convNotifier = ref.read(conversationProvider.notifier);
    _typingNotifier = ref.read(typingProvider.notifier);
    _convNotifier.setActiveConv(widget.convId);
    _ws = ref.read(wsProvider);
    // 上报当前会话给服务端（op=3）+ 本地 conversationProvider。
    // 注:op=3 服务端原本用于「跳过未读计数」,但该守卫已移除,所有 agent 消息一律
    // 计未读,client 端在底部时 _markRead() 归零。op=3 当前主要服务于本地
    // conversationProvider（避免用户在看的会话还闪烁徽章）,服务端仅记录
    // activeConv 状态供后续 participants 模型或其他扩展复用。
    _ws.setActiveConv(widget.convId);
    _msgSub = _ws.messages.where((m) => m.t == 'MESSAGE_CREATE').listen((m) {
      final d = m.d as Map<String, dynamic>?;
      if (d == null) return;
      if (d['conversation_id'] == widget.convId &&
          d['sender_type'] == 'agent') {
        _typingNotifier.clearTyping(widget.agentId);
      }
    });
    // 不需要 Bug C initState 兜底：chatProvider 是 autoDispose，重入会话时
    // state 是全新的（_initialize 重新跑），firstUnreadMessageId 从 null→非 null
    // 自然触发 ref.listen (1) 的定位逻辑。
  }

  @override
  void dispose() {
    // 兜底：pending 的 markMessagesRead 立即同步（不等 await，HTTP 在后台完成）。
    // 用户上滑减了未读但还没等 500ms 同步就退出会话，靠这里保证 server 最终一致。
    if (_markReadDebounce?.isActive ?? false) {
      _markReadDebounce!.cancel();
      _flushPendingReadMsgIds();
    }
    _loadingHideTimer?.cancel();
    _hideMessageMenu(); // 防止页面退出时 Overlay 残留
    _msgSub?.cancel();
    _convNotifier.setActiveConv(null);
    // 通知服务端：用户已离开该会话，后续 agent 消息恢复计未读。
    _ws.setActiveConv(null);
    _scrollCtrl.dispose();
    _selectionFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    // reverse: true 的 ListView 方向语义：pixels=0 → 最新端（视觉底部），
    // pixels=maxScrollExtent → 最老端（视觉顶部）。loadMore 不在这里触发
    //（改由 _onScrollNotification 的 50% 阈值处理，避免定位后链式触发）。
    final px = _scrollCtrl.position.pixels;
    final wasAtBottom = _isAtBottom;
    _isAtBottom = px <= 50;
    if (wasAtBottom != _isAtBottom) {
      // _isAtBottom 变化时触发 rebuild：跳转底部浮标 / 未读浮标的显示条件都依赖
      // !_isAtBottom，不 rebuild 它们不会消失/出现。
      setState(() {});
    }
    if (!wasAtBottom && _isAtBottom) {
      // 用户主动滑到底部时标记已读：清未读浮标 + 分割线。
      ref.read(chatProvider(
          (convId: widget.convId, agentId: widget.agentId)).notifier).markReadAtBottom();
    }
    // 菜单打开时随滚动动态调整定位或取消。
    _updateMenuOnScroll();
    // 用 PostFrameCallback 等 ListView rebuild 完成（新进入视口的消息已 build，
    // GlobalKey.currentContext 有效）。否则 _isMessageInViewport 会因 currentContext
    // 为 null 返 false，浮标数永远不减。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkUnreadSeen();
    });
  }

  /// 检测视口内的未读消息，把新进入视口的未读批量加入 _seenUnreadMsgIds
  /// 并调 decrementUnread(N)。
  ///
  /// 触发点：
  /// - _onScroll 每次滚动
  /// - _isLocating 释放的 PostFrameCallback（处理定位完成时已在视口内的未读）
  ///
  /// 算法：messages 是 newest first，messages[0] = 最新未读，
  /// messages[firstUnreadIdx] = 第一条未读（最老）。
  /// 未读段 = messages[0..firstUnreadIdx]，遍历找「在视口内 + 未在 seen 集合」的。
  void _checkUnreadSeen() {
    if (!mounted || _isLocating) return;
    final chatKey = (convId: widget.convId, agentId: widget.agentId);
    final chatState = ref.read(chatProvider(chatKey));
    if (chatState.unreadCount == 0 || chatState.firstUnreadMessageId == null) {
      return;
    }

    // 不缓存 idx：messages 长度可能因新消息 prepend / 删除变化，缓存会偏移导致误算。
    final firstUnreadIdx = chatState.messages.indexWhere(
      (m) => m.id == chatState.firstUnreadMessageId,
    );
    if (firstUnreadIdx < 0) return;

    final newlySeen = computeNewlySeenUnread(
      messages: chatState.messages,
      firstUnreadIdx: firstUnreadIdx,
      seenUnreadMsgIds: _seenUnreadMsgIds,
      isInViewport: _isMessageInViewport,
    );
    if (newlySeen.isEmpty) return;

    debugPrint('[unreadCheck] idx=$firstUnreadIdx, unread=${chatState.unreadCount}, '
        'seen=${_seenUnreadMsgIds.length}, newlySeen=${newlySeen.length}');
    _seenUnreadMsgIds.addAll(newlySeen);
    ref.read(chatProvider(chatKey).notifier).decrementUnread(newlySeen.length);
    _scheduleMarkReadSync(newlySeen);
  }

  /// 拿消息 bubble 在屏幕的全局 Rect（context 不可用 / 未渲染时返 null）。
  /// 视口检测与菜单定位共用，避免两处重复 localToGlobal 计算。
  Rect? _bubbleGlobalRect(String msgId) {
    final ctx = _bubbleKeys[msgId]?.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(Offset(box.size.width, box.size.height)),
    );
  }

  /// 判断消息当前是否在 ListView 视口内（任何部分可见）。
  bool _isMessageInViewport(String msgId) {
    final rect = _bubbleGlobalRect(msgId);
    if (rect == null) return false;
    final viewport = _listViewRect();
    return rect.bottom > viewport.top && rect.top < viewport.bottom;
  }

  /// 启动 markMessagesRead 同步 debounce：累积 msgIds 到 _pendingReadMsgIds,
  /// 500ms 内若再次调用则重置 timer（取最后一次），fling 期间不打 server。
  void _scheduleMarkReadSync(List<String> msgIds) {
    if (msgIds.isEmpty) return;
    _pendingReadMsgIds.addAll(msgIds);
    _markReadDebounce?.cancel();
    _markReadDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _flushPendingReadMsgIds();
    });
  }

  /// 把 _pendingReadMsgIds 一次性同步给 server，清空集合。
  /// 调 markMessagesRead API，server 返回新 unread_count 后同步到 conversationProvider
  /// 让会话列表徽章立即对齐。
  Future<void> _flushPendingReadMsgIds() async {
    if (_pendingReadMsgIds.isEmpty) return;
    final ids = _pendingReadMsgIds.toList();
    _pendingReadMsgIds.clear();
    debugPrint('[markSync] FLUSH: syncing ${ids.length} ids to server');
    try {
      final res = await ref.read(apiProvider).markMessagesRead(widget.convId, ids);
      final newUnread = (res['unread_count'] as num?)?.toInt() ?? 0;
      // 同步 conversationProvider 的本地未读数（让会话列表徽章立即更新）
      ref.read(conversationProvider.notifier).setUnreadCountLocally(widget.convId, newUnread);
      debugPrint('[markSync] flushed, server unread_count=$newUnread');
    } catch (e) {
      debugPrint('[markSync] flush failed: $e');
      // 失败不重试，下次进入会话 server 仍是旧值，可接受（用户重进会重新触发同步）
    }
  }

  /// 用户主导的滚动事件处理：触发 50% 阈值预加载。
  ///
  /// **区分用户滚动 vs 程序动画的关键**：
  /// 用 `ScrollStartNotification.dragDetails` 一次性判断本次滚动链路是否由
  /// 用户手指触发。`_isUserScrolling` 标记整个滚动链路（含手指松开后的 fling
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
  /// - _isUserScrolling（用户主导，含 fling 惯性）
  /// - 距视觉顶部 ≤ 50% 视口高度（预加载，对齐主流 IM）
  /// - state.isLoadingMore=false + hasMore=true（防抖 + 终止条件）
  ///
  /// _isLocating flag 在定位期间禁用本回调，避免 jumpTo 把 px 推到 maxExtent
  /// 附近时误触发 loadMore。
  bool _isUserScrolling = false;

  bool _onScrollNotification(ScrollNotification notification) {
    if (_isLocating) return false;
    if (!_scrollCtrl.hasClients) return false;

    // 滚动开始：判断本次滚动是否用户主导（dragDetails != null 表示手指触发）
    // 标记整个滚动链路（含 fling 惯性）为用户主导
    if (notification is ScrollStartNotification) {
      _isUserScrolling = notification.dragDetails != null;
      return false;
    }

    if (notification is ScrollEndNotification) {
      _isUserScrolling = false;
      return false;
    }

    if (notification is! ScrollUpdateNotification) return false;
    if (!_isUserScrolling) return false;

    final chatKey = (convId: widget.convId, agentId: widget.agentId);
    final chatState = ref.read(chatProvider(chatKey));
    if (chatState.isLoadingMore || !chatState.hasMore) return false;

    // 预加载阈值：距视觉顶部剩余 ≤ 50% 视口高度就触发。配合 _pageSize=100
    // 和首屏预加载，用户下滑有充足缓冲，避免触顶。
    final px = _scrollCtrl.position.pixels;
    final maxExtent = _scrollCtrl.position.maxScrollExtent;
    final viewport = _scrollCtrl.position.viewportDimension;
    final distanceToTop = maxExtent - px;
    final threshold = viewport * 0.5;
    if (distanceToTop > threshold) return false;

    debugPrint('[scrollUpdate] user scroll near top, distanceToTop=$distanceToTop, '
        'threshold=$threshold, trigger loadMore');
    _loadMore();
    return false;
  }

  /// 上滑到顶部加载更早的历史消息。
  ///
  /// reverse ListView + 数据 append 到 messages 末尾（更老的消息）时，
  /// Flutter 默认 adjustPositionForNewDimensions 保持 px 不变，视觉锚点
  /// 自动保持（firstUnread 仍在视口顶部）。**无需任何手动校正**。
  ///
  /// 之前版本曾加 `jumpTo(oldPixels + delta)` 校正，那是常规 ListView（数据
  /// prepend）的公式，套到 reverse + append 会让 px 跳到新的 maxScrollExtent
  /// （视觉顶部 = 最老消息），表现为「加载历史后跳到顶部」。
  ///
  /// 也**不要**调 ChatScrollObserver.standby：它的 normal 模式假设数据 prepend
  /// 到 refItem 之前（用于新消息到达），append 场景下 refItemIndexAfterUpdate
  /// 会落到新加载的最老消息上，同样跳顶。standby 留给「新消息 prepend」场景用。
  Future<void> _loadMore() async {
    final chatKey = (convId: widget.convId, agentId: widget.agentId);
    final chatState = ref.read(chatProvider(chatKey));
    debugPrint('[loadMore] CHECK: isLoadingMore=${chatState.isLoadingMore}, '
        'hasMore=${chatState.hasMore}');
    if (chatState.isLoadingMore || !chatState.hasMore) return;
    await _notifier.loadMoreHistory();
  }

  /// 滚到底部（最新消息端）。reverse 列表底部 = pixels 0。
  void _doScrollToBottom() {
    if (!_scrollCtrl.hasClients) {
      debugPrint('[doScrollToBottom] ABORT: no clients');
      return;
    }
    final px = _scrollCtrl.position.pixels;
    debugPrint('[doScrollToBottom] CALLED, current px=$px, animating to 0');
    _chatObserver.standby();
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 进入会话后定位到第一条未读消息。
  /// 由 build 内的 ref.listen 监听 firstUnreadMessageId 从 null→非null 触发。
  void _scrollToFirstUnreadIfNeeded() {
    debugPrint('[locateUnread] CALLED');
    final chatKey = (convId: widget.convId, agentId: widget.agentId);
    final chatState = ref.read(chatProvider(chatKey));
    final firstUnreadId = chatState.firstUnreadMessageId;
    debugPrint('[locateUnread] firstUnreadId=$firstUnreadId');
    if (firstUnreadId == null) {
      debugPrint('[locateUnread] ABORT: firstUnreadId is null');
      return;
    }
    if (!_scrollCtrl.hasClients) {
      debugPrint('[locateUnread] ABORT: scrollCtrl has no clients');
      return;
    }

    // 在 newest first 列表中找到第一条未读的 index
    final index = chatState.messages.indexWhere((m) => m.id == firstUnreadId);
    debugPrint('[locateUnread] index=$index, messages.length=${chatState.messages.length}, '
        'messages.last.id=${chatState.messages.isEmpty ? null : chatState.messages.last.id}');
    if (index < 0) {
      debugPrint('[locateUnread] ABORT: firstUnreadId not found in messages');
      return;
    }

    // Bug A 自旋等待：ListViewObserver 内部 sliverContexts 在 initState 的
    // PostFrameCallback 中填充。即使我们用了 loading overlay 让 ListViewObserver
    // 提前挂载，jumpTo 仍可能在 sliverContexts 还空时被调用 → 静默失败。
    if (_observerController.sliverContexts.isEmpty) {
      debugPrint('[locateUnread] sliverContexts empty, retrying next frame');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToFirstUnreadIfNeeded();
      });
      return;
    }

    // 进入定位状态：禁用 _onScroll 触发的 loadMore
    _isLocating = true;

    // 第一步：用 observerController.jumpTo 把 firstUnread 拉进可视区让其渲染。
    // jumpTo 是 Future，内部会逐步翻页直到目标 index 进可见区。
    final pxBefore = _scrollCtrl.position.pixels;
    debugPrint('[locateUnread] before jumpTo: px=$pxBefore, will jumpTo index=$index, '
        'sliverContexts=${_observerController.sliverContexts.length}');
    _observerController.jumpTo(index: index, alignment: 0.3).then((_) async {
      // jumpTo 完成后 firstUnread 必然已渲染，BuildContext 可拿
      if (!mounted) {
        _isLocating = false;
        debugPrint('[locateUnread] jumpTo completed but not mounted');
        return;
      }
      final key = _bubbleKeys[firstUnreadId];
      final ctx = key?.currentContext;
      if (ctx == null) {
        _isLocating = false;
        debugPrint('[locateUnread] after jumpTo: still no ctx for $firstUnreadId');
        return;
      }
      final pxBeforeEnsure =
          _scrollCtrl.hasClients ? _scrollCtrl.position.pixels : null;
      debugPrint('[locateUnread] jumpTo done, calling ensureVisible, px before=$pxBeforeEnsure');
      // 第二步：ensureVisible 精确对齐（无动画，消除视觉滚动感）。
      // jumpTo 的 alignment 在 reverse ListView 下不够精确，需 ensureVisible 兜底。
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.3,
        duration: Duration.zero,
        curve: Curves.easeOut,
      );
      if (mounted && _scrollCtrl.hasClients) {
        debugPrint('[locateUnread] after ensureVisible: px=${_scrollCtrl.position.pixels}');
      }
      // 释放定位状态，下一帧恢复 loadMore 监听
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _isLocating = false;
        debugPrint('[locateUnread] _isLocating released');
        // 首屏预加载：定位完成后主动拉一页历史。
        // 定位点（firstUnread）是 messages.last（视觉顶部），若不预加载，
        // 用户一下滑就 overdrag 触顶，50% 阈值无空间生效。预加载 100 条
        // 历史后，maxExtent 立即增大，用户下滑到 50% 阈值时正常预加载，
        // 链式生效避免触顶。
        final chatKey = (convId: widget.convId, agentId: widget.agentId);
        ref.read(chatProvider(chatKey).notifier).loadMoreHistory();
        // 定位完成时 firstUnread 已在视口内（可能短消息密集首屏还有更多未读），
        // 主动检查一次，让浮标数立即反映「已看到 N 条」。
        _checkUnreadSeen();
      });
    });
    final pxRightAfterJump = _scrollCtrl.hasClients ? _scrollCtrl.position.pixels : null;
    debugPrint('[locateUnread] rightAfter jumpTo call: px=$pxRightAfterJump');
  }

  Future<void> _markRead() async {
    ref.read(conversationProvider.notifier).markReadLocally(widget.convId);
    try {
      await ref.read(apiProvider).markConversationRead(widget.convId);
    } catch (_) {
      // 静默：markRead 失败不影响聊天，下次进入会重试
    }
  }

  ChatNotifier get _notifier => ref.read(
    chatProvider((convId: widget.convId, agentId: widget.agentId)).notifier,
  );

  String get _agentName {
    final agent = ref.watch(agentByIdProvider(widget.agentId));
    return agent?.name ?? '聊天';
  }

  // ============ 长按菜单 ============

  /// 长按消息:显示浮动菜单(OverlayEntry，绝对定位锚钉在可见区内)。
  /// 选择由常驻 SelectableRegion 内置长按选词完成（落点选词+拉杆），本方法只弹菜单。
  void _showMessageMenu(ChatMessage msg) {
    _hideMessageMenu();
    final placement = _computeMenuPlacement(msg.id);
    if (placement == null) return; // 消息不在可见区,不弹菜单
    _activeSelectMsgId = msg.id;
    _menuPlacement = placement;
    _menuEntry = OverlayEntry(builder: (_) => _buildMenu(msg, placement));
    Overlay.of(context).insert(_menuEntry!);
  }

  Widget _buildMenu(ChatMessage msg, _MenuPlacement p) {
    return MessageContextMenu(
      left: p.left,
      top: p.top,
      tailOffsetX: p.tailOffsetX,
      pointDown: p.pointDown,
      onCopy: () {
        _copySelectedOrFull(msg);
        _hideMessageMenu();
      },
      onDelete: () {
        _hideMessageMenu();
        _confirmDelete([msg.id]);
      },
      onSelect: () {
        _hideMessageMenu();
        setState(() {
          _selectionMode = true;
          _selectedIds
            ..clear()
            ..add(msg.id);
        });
      },
      onDismiss: _hideMessageMenu,
    );
  }

  void _hideMessageMenu() {
    _menuEntry?.remove();
    _menuEntry = null;
    _activeSelectMsgId = null;
    _menuPlacement = null;
    // 菜单关闭 → 清选区(常驻 SelectableRegion)
    _selectionKey.currentState?.clearSelection();
    _selectedText = null;
  }

  /// 计算菜单定位(left/top/tailOffsetX/pointDown，全屏幕绝对坐标)。
  /// 消息不在可见区返回 null。
  ///
  /// **锚钉效果**：菜单跟随消息（贴在消息上/下方），但用 clamp 钉在可见区边缘，
  /// 不溢出 AppBar/输入栏。消息在中央时跟随；消息接近边缘时钉住。
  ///
  /// - top: 菜单顶缘屏幕 y = clamp(期望Y, viewport.top, viewport.bottom - menuH)
  /// - left: 菜单左缘屏幕 x，居中于消息中心并 clamp 不超屏
  /// - tailOffsetX: 三角在菜单内的位置，指向消息中心
  /// - pointDown: 菜单在消息上方→三角朝下
  _MenuPlacement? _computeMenuPlacement(String msgId) {
    final rect = _bubbleGlobalRect(msgId);
    if (rect == null) return null;

    // 可见区 = ListView 在屏幕的矩形（扣除 AppBar 和输入栏）。
    final viewport = _listViewRect();

    // 出屏判定:消息完全在可见区外 → 取消菜单
    if (rect.bottom <= viewport.top || rect.top >= viewport.bottom) {
      return null;
    }

    // 上下方向 + 期望 Y：优先上方（菜单贴消息上方），不够则下方，都不够选大的。
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
    final left = (rect.center.dx - kMenuWidth / 2).clamp(
      viewport.left + 8,
      viewport.right - kMenuWidth - 8,
    );
    // 三角指向消息中心:菜单内 x = 消息中心 - 菜单左缘
    final tailOffsetX = (rect.center.dx - left).clamp(
      kMenuTailHalfWidth,
      kMenuWidth - kMenuTailHalfWidth,
    );

    return _MenuPlacement(
      left: left,
      top: top,
      tailOffsetX: tailOffsetX,
      pointDown: pointDown,
    );
  }

  /// 取 ListView 在屏幕的矩形（可见区，已扣除 AppBar 和输入栏）。
  /// 拿不到 RenderBox 时兜底用全屏。
  Rect _listViewRect() {
    final box = _listViewKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return Rect.fromPoints(
        box.localToGlobal(Offset.zero),
        box.localToGlobal(Offset(box.size.width, box.size.height)),
      );
    }
    return Offset.zero & MediaQuery.of(context).size;
  }

  /// 当前会话的消息列表（用于滚动重算时按 id 查消息）。
  List<ChatMessage> get _currentMessages {
    final chatKey = (convId: widget.convId, agentId: widget.agentId);
    return ref.read(chatProvider(chatKey)).messages;
  }

  /// 打开会话级图片画廊：收集会话所有图，定位被点击图索引，Hero 过渡进画廊。
  ///
  /// 由 MessageBubble → ImageContentRenderer 的点击回调注入（rc.openGallery）。
  /// 收集结果为空（无任何图片，理论不应发生）则直接返回，不打开空画廊。
  void _openGallery(String fileId, List<ChatMessage> messages) {
    final baseUrl = ref.read(settingsProvider);
    final token = ref.read(authProvider).token ?? '';
    final images = collectConversationImages(messages, baseUrl, token);
    if (images.isEmpty) return;
    final index = images.indexWhere((g) => g.fileId == fileId);
    // 用全透明路由：页面本身无入场/退场动画（避免黑色背景横划覆盖 Hero），
    // 只有 Hero 共享元素的飞行过渡可见，背景随 Hero 自然淡入/淡出。
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) => ZoomableGallery(
          images: images,
          initialIndex: index < 0 ? 0 : index,
        ),
      ),
    );
  }

  /// 滚动时动态调整菜单:消息出屏则关闭,定位变化则重建 OverlayEntry。
  void _updateMenuOnScroll() {
    final msgId = _activeSelectMsgId;
    if (msgId == null || _menuEntry == null) return;
    final newPlacement = _computeMenuPlacement(msgId);
    if (newPlacement == null) {
      _hideMessageMenu();
      return;
    }
    // 定位没变就不重建(滚动每帧都触发,避免无谓重建)
    if (_menuPlacement == newPlacement) return;
    _menuPlacement = newPlacement;
    // 重建 OverlayEntry 让菜单重新定位（绝对定位随滚动重算 top/left）
    final msg = _currentMessages.firstWhere(
      (m) => m.id == msgId,
      orElse: () => _currentMessages.first,
    );
    _menuEntry!.remove();
    _menuEntry = OverlayEntry(builder: (_) => _buildMenu(msg, newPlacement));
    Overlay.of(context).insert(_menuEntry!);
  }

  /// 提取消息纯文本(支持 text / markdown msg_type)。
  String _extractText(ChatMessage msg) {
    final data = msg.content['data'] as Map<String, dynamic>?;
    return (data?['text'] as String?) ?? '';
  }

  /// 复制当前选区；选区为空时降级复制全文。无文本则提示。
  ///
  /// 读常驻 SelectableRegion 的 onSelectionChanged 缓存（用户可能拖动拉杆
  /// 选了部分文字），读不到/为空则复制消息全文。
  Future<void> _copySelectedOrFull(ChatMessage msg) async {
    final sel = _selectedText;
    final text = (sel != null && sel.isNotEmpty) ? sel : _extractText(msg);
    if (text.isEmpty) {
      if (mounted) {
        showAppSnackBar(context, '该消息无可复制文本');
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showAppSnackBar(context, '已复制', type: SnackBarType.success);
    }
  }

  // ============ 多选模式 ============

  void _exitSelectionMode() {
    setState(() {
      _selectedIds.clear();
      _selectionMode = false;
    });
  }

  void _toggleSelect(String msgId) {
    setState(() {
      if (_selectedIds.contains(msgId)) {
        _selectedIds.remove(msgId);
      } else {
        _selectedIds.add(msgId);
      }
    });
  }

  /// 多选模式底部"复制":把所有选中消息文本换行拼接复制。
  /// 若选中的全是图片/文件(无文本),提示而非复制空内容。
  Future<void> _batchCopy() async {
    if (_selectedIds.isEmpty) return;
    final chatKey = (convId: widget.convId, agentId: widget.agentId);
    final chatState = ref.read(chatProvider(chatKey));
    final texts = chatState.messages
        .where((m) => _selectedIds.contains(m.id))
        .map(_extractText)
        .where((t) => t.isNotEmpty)
        .join('\n');
    if (texts.isEmpty) {
      if (mounted) {
        showAppSnackBar(context, '选中的消息无可复制文本');
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: texts));
    if (mounted) {
      showAppSnackBar(context, '已复制', type: SnackBarType.success);
    }
  }

  /// 删除确认(单条/批量共用)。弹 showAppDialog 二次确认 → 调 provider 乐观删除。
  Future<void> _confirmDelete(List<String> ids) async {
    if (ids.isEmpty) return;
    showAppDialog(
      context: context,
      title: '删除消息',
      content: Text(
        ids.length == 1 ? '确定删除这条消息吗?' : '确定删除 ${ids.length} 条消息吗?',
      ),
      confirmText: '删除',
      onConfirm: () async {
        final wasSelectionMode = _selectionMode;
        try {
          await _notifier.deleteMessages(ids);
          // 清理已删消息的 GlobalKey(防长期会话 Map 无限增长)
          _bubbleKeys.removeWhere((k, _) => ids.contains(k));
          if (!mounted) return;
          // 删除成功后若是多选模式,清空选中并退出
          if (wasSelectionMode) {
            setState(() {
              _selectedIds.clear();
              _selectionMode = false;
            });
          }
        } catch (_) {
          // provider 失败已回滚,UI 层提示。多选模式不退出(让用户重试)。
          if (mounted) {
            showAppSnackBar(context, '删除失败,请重试', type: SnackBarType.error);
          }
        }
      },
    );
  }

  // ============ build ============

  @override
  Widget build(BuildContext context) {
    final chatKey = (convId: widget.convId, agentId: widget.agentId);
    final chatState = ref.watch(chatProvider(chatKey));
    // 关键节点日志（只打印关键状态，避免每次 build 刷屏）
    debugPrint('[build] messages=${chatState.messages.length}, '
        'firstUnread=${chatState.firstUnreadMessageId}, '
        'hasMore=${chatState.hasMore}, '
        'showUnreadSeparator=${chatState.showUnreadSeparator}, '
        'unreadCount=${chatState.unreadCount}, '
        '_pendingScroll=$_pendingScroll, _didLocateUnread=$_didLocateUnread');
    // 监听状态变化，处理三类副作用：
    // (1) 未读定位：firstUnreadMessageId 从 null→非null（_initialize 完成）时触发定位。
    //     用 _didLocateUnread 标记防重复（_initialize 只会成功一次）。
    // (2) 新消息计数：messages 长度增长时，按 _isAtBottom 决定增哪个计数器。
    // (3) pendingScroll：自己发的消息 echo 回来时滚到底部。
    ref.listen(chatProvider(chatKey), (prev, next) {
      debugPrint('[listen] prev: messages=${prev?.messages.length}, '
          'firstUnread=${prev?.firstUnreadMessageId}, hasMore=${prev?.hasMore}; '
          'next: messages=${next.messages.length}, '
          'firstUnread=${next.firstUnreadMessageId}, hasMore=${next.hasMore}');

      // loadMore overlay 显示控制：开始加载立刻显示，完成后延迟 300ms 隐藏。
      // 直接绑定 chatState.isLoadingMore 会因 loadMore 太快用户看不到。
      if (prev?.isLoadingMore == false && next.isLoadingMore) {
        _loadingHideTimer?.cancel();
        _loadingHideTimer = null;
        setState(() {}); // 触发重建显示 overlay
      } else if (prev?.isLoadingMore == true && !next.isLoadingMore) {
        final timer = Timer(const Duration(milliseconds: 300), () {
          if (mounted) {
            _loadingHideTimer = null;
            setState(() {});
          }
        });
        _loadingHideTimer = timer;
        setState(() {});
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
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToFirstUnreadIfNeeded();
        });
      } else if (prevFirstUnread == null &&
          next.firstUnreadMessageId != null &&
          _didLocateUnread) {
        debugPrint('[listen] (1) locateUnread already done (_didLocateUnread=true)');
      }

      // (2) messages 增长：区分「新消息 prepend 头部」vs「loadMore append 末尾」
      // - 新消息 prepend：视觉底部多了一条，Flutter 默认 px 不变会让所有原 item
      //   的 offset 下移 newItemHeight，视口漂移、firstUnread 被推出顶部。
      //   → 不在底部时调 ChatScrollObserver.standby，让 px 同步增加 delta 抵消下推。
      // - loadMore append：更老消息进 messages 末尾（视觉顶部），Flutter 默认 px
      //   不变就让 firstUnread 视觉位置自动保持，**不能**调 standby（库假设 prepend，
      //   会算到新最老消息上跳顶）。
      final oldLen = prev?.messages.length ?? 0;
      final newLen = next.messages.length;
      if (newLen > oldLen && oldLen > 0) {
        final isPrepend = prev!.messages.first.id != next.messages.first.id;
        if (isPrepend) {
          final changeCount = newLen - oldLen;
          final isSelfEcho = next.messages.first.senderType == 'user';
          debugPrint('[listen] (2) newMsg prepend $oldLen→$newLen, '
              '_isAtBottom=$_isAtBottom, changeCount=$changeCount, '
              'isSelfEcho=$isSelfEcho');
          if (isSelfEcho) {
            // 自己发消息的 echo：交给 (3) 分支滚到底看自己消息，不增计数（自己发的不算新消息）
          } else if (_isAtBottom) {
            // 在底部 + 对方新消息：滚到底让新消息可见
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => _doScrollToBottom(),
            );
            _markRead();
          } else {
            // 不在底部 + 对方新消息：调 ChatScrollObserver.standby 保持视口锚点 +
            // 增加未读计数（统一未读浮标提示）。
            _chatObserver.standby(changeCount: changeCount);
            _notifier.incrementUnread();
            // 同步会话列表徽章：conversationProvider 内置 _onMessageCreate 在
            // isActive=true 时不 +1（与 server 对齐），但浮标 +1 了，这里手动同步
            // 让两端一致，否则返回列表时徽章比浮标少。
            ref
                .read(conversationProvider.notifier)
                .incrementUnreadLocally(widget.convId);
          }
        } else {
          debugPrint('[listen] (2) loadMore append $oldLen→$newLen, '
              'skip standby (Flutter default keeps px)');
        }
      }

      // (3) 处理回显消息（自己发的消息到达后滚到底，让用户看到自己刚发的消息）。
      // 关键约束 1：仅「定位未完成」时跳过——(1) jumpTo 只在 firstUnread 首次设置时
      //   触发一次（_didLocateUnread 守卫），定位完成后即使 firstUnread 仍在 state 里
      //   （用户没滚到底清除），自己 echo 也应该滚到底看自己消息。
      // 关键约束 2：仅「自己 echo」（senderType=user）才触发——对方发的新消息
      //   由 (2) 分支按 _isAtBottom 处理（在底部滚/不在底部增计数），不能在这里误滚到底。
      if (next.messages.isEmpty) {
        debugPrint('[listen] (3) skip pendingScroll: messages empty');
        return;
      }
      if (!_didLocateUnread && next.firstUnreadMessageId != null) {
        debugPrint('[listen] (3) skip pendingScroll: still locating');
        return; // 定位进行中：让 (1) 的 jumpTo 生效
      }
      if (next.messages.first.senderType != 'user') {
        debugPrint('[listen] (3) skip pendingScroll: not self echo '
            '(senderType=${next.messages.first.senderType})');
        return; // 对方新消息：由 (2) 分支处理
      }
      final prevFirstId = prev?.messages.isEmpty == true
          ? null
          : prev?.messages.first.id;
      if (prevFirstId != next.messages.first.id) {
        debugPrint('[listen] (3) set pendingScroll=true (self echo)');
        _pendingScroll = true;
      }
    });

    final agentName = _agentName;
    final isTyping = ref.watch(
      typingProvider.select((m) => m[widget.agentId] ?? false),
    );
    final agentStatus = ref.watch(agentByIdProvider(widget.agentId))?.status;

    if (_pendingScroll && (chatState.messages.isNotEmpty || isTyping)) {
      debugPrint('[build] _pendingScroll=true → scheduling _doScrollToBottom');
      _pendingScroll = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _doScrollToBottom());
    }

    final subtitle = isTyping
        ? '对方正在输入...'
        : (agentStatus == AgentStatus.online ? '在线' : '离线');

    // 多选模式用深色 AppBar,普通态用原 AppBar。
    final appBar = _selectionMode
        ? AppBar(
            backgroundColor: const Color(0xFF2A2A2A),
            foregroundColor: Colors.white,
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: _exitSelectionMode,
            ),
            title: Text('已选择 ${_selectedIds.length} 条'),
            centerTitle: true,
          )
        : AppBar(
            backgroundColor: const Color(0xFFEDEDED),
            surfaceTintColor: Colors.transparent,
            // 下边框:极细线,深于背景色
            shape: const Border(
              bottom: BorderSide(color: Color(0xFFD9D9D9), width: 0.5),
            ),
            centerTitle: true,
            title: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  agentName,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.normal,
                  ),
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    // 在线/打字中=绿,离线=灰。在线状态用颜色直观区分。
                    color: (isTyping || agentStatus == AgentStatus.online)
                        ? const Color(0xFF07C160)
                        : const Color(0xFF999999),
                  ),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.more_vert),
                tooltip: '会话详情',
                onPressed: () =>
                    context.push('/conversations/${widget.convId}/detail'),
              ),
            ],
          );

    // PopScope:多选模式拦截返回键(优先退出多选,而非离开页面)。
    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelectionMode();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFEDEDED),
        appBar: appBar,
        body: Column(
          children: [
            Expanded(
              // 始终挂载 SelectableRegion + ListViewObserver + ListView，
              // 让 ListViewObserver 在 initState 后立即注册 PostFrameCallback 填充
              // sliverContexts。loading 与空会话提示作为 overlay 叠加在 Stack 中。
              // 修复 Bug A：原来 messages.isEmpty 时整个 ListView 被替换成 Center(Text)，
              // ListViewObserver 首次挂载滞后于 jumpTo 的 PostFrameCallback，
              // 导致 sliverContexts 为空、jumpTo 静默失败。
              child: SelectableRegion(
                key: _selectionKey,
                focusNode: _selectionFocusNode,
                selectionControls: materialTextSelectionHandleControls,
                contextMenuBuilder: (context, selectableRegionState) =>
                    const SizedBox.shrink(),
                onSelectionChanged: (c) => _selectedText = c?.plainText,
                child: Stack(
                  children: [
                    NotificationListener<ScrollNotification>(
                      onNotification: _onScrollNotification,
                      child: ListViewObserver(
                        controller: _observerController,
                        child: ListView.builder(
                        key: _listViewKey,
                        reverse: true,
                        controller: _scrollCtrl,
                        // ChatObserverClampingScrollPhysics 是 ChatScrollObserver.standby
                        // 的官方要求（wiki 标准）。Bouncing 的弹性 overscroll 会干扰 standby
                        // 的 px 同步，导致 agent 新消息 prepend 时视口被「上顶」。
                        // loadMore 不依赖触顶 overscroll（_onScrollNotification 的 50% 阈值
                        // 预加载会提前触发），Clamping 不破坏 loadMore 体验。
                        physics: ChatObserverClampingScrollPhysics(
                          observer: _chatObserver,
                        ),
                        shrinkWrap: _chatObserver.isShrinkWrap,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        itemCount:
                            chatState.messages.length +
                            (isTyping ? 1 : 0) +
                            (chatState.hasMore ? 1 : 0),
                        itemBuilder: (_, i) {
                          if (isTyping && i == 0) {
                            return const TypingBubble();
                          }
                          final msgIndex = isTyping ? i - 1 : i;

                          // 顶部加载指示器（reverse 列表的最后一项）
                          final loadIndicatorIndex =
                              chatState.messages.length +
                              (isTyping ? 1 : 0);
                          if (i == loadIndicatorIndex &&
                              chatState.hasMore) {
                            return LoadMoreIndicator(
                              isLoading: chatState.isLoadingMore,
                            );
                          }

                          // msgIndex 越界保护：itemCount 计算含 typing/hasMore，
                          // 但 itemBuilder 在边界条件下可能被请求超出 messages 范围的 index
                          // （如 loading overlay 期间 itemCount 临时为 0+1=1，i=0 但 messages 空）。
                          // 此时返回空 SizedBox 占位，避免 RangeError。
                          if (msgIndex < 0 ||
                              msgIndex >= chatState.messages.length) {
                            return const SizedBox.shrink();
                          }

                          final msg = chatState.messages[msgIndex];
                          final showTime =
                              msgIndex == chatState.messages.length - 1 ||
                              msg.createdAt
                                      .difference(
                                        chatState
                                            .messages[msgIndex + 1]
                                            .createdAt,
                                      )
                                      .inMinutes
                                      .abs() >=
                                  5;

                          // 判断是否在此消息前显示未读分隔线
                          final showSeparatorBefore =
                              chatState.showUnreadSeparator &&
                              chatState.firstUnreadMessageId == msg.id;

                          // 每条消息一个 GlobalKey,用于拿 RenderObject 算菜单定位/出屏判定。
                          final bubbleKey = _bubbleKeys.putIfAbsent(
                            msg.id,
                            () => GlobalKey(),
                          );
                          final bubble = MessageBubble(
                            key: bubbleKey,
                            message: msg,
                            isMe: msg.senderType == 'user',
                            baseUrl: ref.read(settingsProvider),
                            token: ref.read(authProvider).token ?? '',
                            conversationMessages: chatState.messages,
                            openGallery: (fileId) =>
                                _openGallery(fileId, chatState.messages),
                            selectionMode: _selectionMode,
                            selected: _selectedIds.contains(msg.id),
                            onLongPressStart: _selectionMode
                                ? null
                                : (details) => _showMessageMenu(msg),
                            onTapSelect: _selectionMode
                                ? () => _toggleSelect(msg.id)
                                : null,
                          );

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (showTime)
                                Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      formatTimestamp(msg.createdAt),
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF999999),
                                      ),
                                    ),
                                  ),
                                ),
                              if (showSeparatorBefore)
                                const UnreadSeparator(),
                              bubble,
                            ],
                          );
                        },
                      ), // ListView.builder
                      ), // ListViewObserver
                    ), // NotificationListener

                    // 首屏初始化中：loading overlay 覆盖列表
                    if (chatState.isInitialLoading)
                      const Positioned.fill(
                        child: Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF07C160),
                            strokeWidth: 2,
                          ),
                        ),
                      ),

                    // 加载历史 overlay：顶部细进度条。
                    // LoadMoreIndicator 是列表 item，预加载时在视口外看不到；此 overlay 固定在
                    // 视口顶部给用户「正在拉取」的视觉反馈。
                    // 显示时机：isLoadingMore=true 期间 + 完成后延迟 300ms（_loadingHideTimer 控制），
                    // 让 loadMore 极快（<100ms）时用户也能看到反馈。
                    if (chatState.isLoadingMore || _loadingHideTimer != null)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: SizedBox(
                          height: 1,
                          child: LinearProgressIndicator(
                            backgroundColor: Colors.transparent,
                            valueColor: AlwaysStoppedAnimation(
                              const Color(0xFF07C160),
                            ),
                          ),
                        ),
                      ),

                    // 空会话提示：初始化完成且无消息无 typing 时显示
                    if (!chatState.isInitialLoading &&
                        chatState.messages.isEmpty &&
                        !isTyping)
                      const Positioned.fill(
                        child: Center(
                          child: Text(
                            '发送消息开始对话',
                            style: TextStyle(
                              color: Color(0xFF999999),
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),

                    // 统一未读浮标：有未读（历史未读 + 会话内新消息合并）且不在底部时显示
                    if (chatState.unreadCount > 0 && !_isAtBottom)
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: UnreadNavBadge(
                          count: chatState.unreadCount,
                          onTap: () async {
                            debugPrint('[unreadBadge] TAP: scroll to bottom + jumpToBottom');
                            _doScrollToBottom();
                            await _notifier.jumpToBottom();
                          },
                        ),
                      ),

                    // 跳转底部浮标：无未读 + 不在底部时显示
                    // 与未读浮标互斥（条件不会同时成立）
                    // 场景：进入无未读会话 → 上滑读历史 → 提供快捷回最新的入口
                    if (chatState.unreadCount == 0 && !_isAtBottom)
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: JumpToBottomButton(
                          onTap: () {
                            debugPrint('[jumpBtn] TAP: scroll to bottom');
                            _doScrollToBottom();
                          },
                        ),
                      ),
                  ], // children of Stack
                ), // Stack
              ), // SelectableRegion
            ),
            if (_selectionMode)
              _buildSelectionBottomBar()
            else
              _buildInputBar(),
          ],
        ),
      ),
    );
  }

  /// 多选模式底部固定操作栏:复制 / 删除 两个纯 icon 按钮。
  /// 未选任何消息(N=0)时按钮置灰不可点。
  Widget _buildSelectionBottomBar() {
    final hasSelection = _selectedIds.isNotEmpty;
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
              color: hasSelection ? Colors.black87 : Colors.grey,
              onPressed: hasSelection ? _batchCopy : null,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              color: hasSelection ? const Color(0xFFFA5151) : Colors.grey,
              onPressed: hasSelection
                  ? () => _confirmDelete(_selectedIds.toList())
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return MessageInputBar(
      onSend: _send,
      onPickFile: _pickFile,
      onTakePhoto: _takePhoto,
      onPickAlbum: _pickAlbum,
    );
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.pickFiles();
    if (result == null || result.files.isEmpty) return;

    try {
      final api = ref.read(apiProvider);
      final file = result.files.first;
      final fileId = await api.uploadFile(file.path!);

      final ext = file.path!.toLowerCase().substring(
        file.path!.lastIndexOf('.'),
      );
      final msgType = _imageExts.contains(ext) ? MsgType.image : MsgType.file;
      _notifier.sendFile(fileId, msgType);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '上传失败: $e', type: SnackBarType.error);
      }
    }
  }

  void _send(String text) {
    if (text.isEmpty) return;
    _notifier.sendText(text);
  }

  Future<void> _takePhoto() async {
    final asset = await CameraPicker.pickFromCamera(context);
    if (asset == null) return;
    await _uploadAndSendAsset(asset, MsgType.image);
  }

  Future<void> _pickAlbum() async {
    final result = await AssetPicker.pickAssets(
      context,
      // 复用 avatar_picker 的共享配置（简体中文 + 品牌绿 + 相册名汉化），
      // 避免两处配置漂移。详见 defaultAssetPickerConfig 注释。
      pickerConfig: defaultAssetPickerConfig,
    );
    if (result == null || result.isEmpty) return;
    await _uploadAndSendAsset(result.first, MsgType.image);
  }

  /// 把 AssetEntity 写成临时文件 → uploadFile → sendFile。
  /// 失败 SnackBar 提示(fail fast,不吞异常)。
  Future<void> _uploadAndSendAsset(AssetEntity asset, MsgType msgType) async {
    final file = await asset.file;
    if (file == null) {
      if (mounted) {
        showAppSnackBar(context, '无法读取文件', type: SnackBarType.error);
      }
      return;
    }
    try {
      final api = ref.read(apiProvider);
      final fileId = await api.uploadFile(file.path);
      _notifier.sendFile(fileId, msgType);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '上传失败: $e', type: SnackBarType.error);
      }
    }
  }
}

/// 菜单定位缓存（用于滚动时比较，变化才重建 OverlayEntry）。
/// 全部用屏幕绝对坐标（脱离 LayerLink follower，实现锚钉效果）。
class _MenuPlacement {
  /// 菜单左缘屏幕 x（clamp 不超屏）。
  final double left;

  /// 菜单顶缘屏幕 y（clamp 在可见区内，钉边缘）。
  final double top;

  /// 三角在菜单内的水平偏移（指向消息中心）。
  final double tailOffsetX;

  /// 三角朝向：true=朝下（菜单在消息上方），false=朝上。
  final bool pointDown;

  const _MenuPlacement({
    required this.left,
    required this.top,
    required this.tailOffsetX,
    required this.pointDown,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _MenuPlacement &&
          left == other.left &&
          top == other.top &&
          tailOffsetX == other.tailOffsetX &&
          pointDown == other.pointDown;

  @override
  int get hashCode => Object.hash(left, top, tailOffsetX, pointDown);
}
