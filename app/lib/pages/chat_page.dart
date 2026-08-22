import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:scrollview_observer/scrollview_observer.dart';
import 'package:wanling_core/models/agent.dart' show AgentCategory, AgentStatus;
import 'package:wanling_core/models/slash_command.dart';
import 'package:wanling_core/models/ws_message.dart' show WSMessage;
import 'package:wanling_core/providers/agent_modes_provider.dart'
    show agentModesProvider;
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart';
import 'package:wanling_core/providers/agent_status_provider.dart'    show AgentStatusType, agentStatusProvider;
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart'
    show ChatNotifier, chatProvider, wsProvider;
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/friend_provider.dart';
import 'package:wanling_core/providers/typing_provider.dart';
import 'package:wanling_core/services/file_download_service.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_core/utils/chat/message_preview.dart' show extractMessageText;
import 'package:wanling_core/utils/chat/render_box_utils.dart' show globalRectOf;
import 'package:wanling_core/utils/aggregate_card_state.dart' show hasGeneratingAggregateCard;
import '../router_helpers.dart' show openFileBrowser;
import '../widgets/chat/chat_app_bar.dart';
import '../widgets/chat/chat_input_bar.dart';
import '../widgets/chat/chat_list_overlays.dart';
import '../widgets/chat/typing_bubble.dart';
import '../widgets/chat/env_meta_strip.dart' show EnvMetaStrip;
import '../widgets/chat/model_picker_sheet.dart' show ModelPickerDialog;
import '../widgets/chat/mode_picker_sheet.dart' show ModePickerDialog;
import '../widgets/chat/session_meta_strip.dart' show SessionMetaStrip;
import 'package:wanling_core/widgets/chat/shimmer_text.dart';
import '../widgets/chat/slash_command_sheet.dart';
import '../widgets/chat/slash_handle.dart';
import '../widgets/chat/stop_bar.dart' show StopBar;
import '../widgets/chat/chat_message_item_builder.dart';
import '../widgets/chat/chat_state_listener.dart';
import '../widgets/chat/conv_sync_controller.dart';
import '../widgets/chat/file_download_controller.dart';
import '../widgets/chat/friend_deleted_banner.dart';
import '../widgets/chat/message_menu_controller.dart'
    show MessageMenuController, MessageMenuContext;
import '../widgets/chat/input_controller.dart';
import '../widgets/chat/jump_controller.dart';
import '../widgets/chat/dual_sliver_physics.dart';
import '../widgets/chat/chat_loading_skeleton.dart';
import '../widgets/chat/load_more_controller.dart';
import '../widgets/chat/load_more_indicator.dart';
import '../widgets/chat/multi_select_controller.dart';
import '../widgets/chat/selection_bottom_bar.dart' show SelectionBottomBar;
import '../widgets/chat/unread_locator_controller.dart';
import '../widgets/chat/unread_tracker_controller.dart';
import 'package:wanling_core/utils/snackbar.dart';
import '../widgets/feedback/app_dialog.dart';

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
/// - MultiSelectController 封装多选状态 + 行为(进入/退出/勾选/批量复制)
/// - 长按消息由 MessageMenuController 弹浮动菜单(OverlayEntry 绝对定位锚钉)
class ChatPage extends ConsumerStatefulWidget {
  final String convId;

  /// agentId 仅用于显示 agent 信息（typing / AppBar / 在线状态）。
  /// 可空：user-user DM 会话无 agent，传 null。
  /// 实际消息发送走 conversationId 路由（N 方 participants 模型）。
  final String? agentId;

  const ChatPage({super.key, required this.convId, this.agentId});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  /// onAttach 监听 isScrollingNotifier:拖动/惯性/动画滚动状态权威信号。
  /// 滚动完全停止时补一次「回底部恢复跟随」(px 停稳后 _onScroll 不再触发)。
  /// initState 创建(字段初始化器不能引用实例方法 _onScrollStateChanged)。
  late final ScrollController _scrollCtrl;

  // scrollview_observer：跨 sliver index 滚动(双 sliver 定位)
  late final SliverObserverController _observerController;

  /// 滚动位置跟踪：是否在底部(px >= maxScrollExtent - 50)
  bool _isAtBottom = true;

  /// 用户是否主动滚动离开底部(拖动/惯性离开 50px 容差)。
  ///
  /// 替代 [_isAtBottom] 作为「贴底跟随」的判定条件(传给 ChatStateListener):
  /// - 用户拖动开始(ScrollStartNotification.dragDetails != null)→ true;
  /// - 滚动完全停稳后回到底部 50px 内(程序化滚底 / isScrollingNotifier 变 false)→ false。
  /// 卡片等大高度非流式消息插入使 maxScrollExtent 跳增但 px 不变,_isAtBottom
  /// 不会及时更新;scrollToBottom 又会让 _isAtBottom 在动画窗口内翻 false,
  /// 导致流式跟随失效。用户主动滚动离开才应停止跟随,被动被新内容顶出不视为离开。
  ///
  /// 初始为 true:挡住进入会话初始窗口期的流式跟随抢跑。pendingInitialScroll
  /// (无未读)的 jumpTo 完成后会显式复位为 false;onLocateComplete(有未读)
  /// 显式保持 true(停历史阅读)。两条路径都在揭开前显式表态,不依赖「jumpTo
  /// 必然触发 _onScroll 且 isScrolling 为 false」的时序假设。
  bool _userScrolledAway = true;

  /// 滚动状态变化回调(isScrollingNotifier 驱动)。
  ///
  /// 拖动/惯性期间 isScrolling=true,禁止复位 [_userScrolledAway](否则流式跟随
  /// 会把视口抢回底部,上滑看历史停不住);滚动完全停稳(isScrolling=false)且已
  /// 回到底部时恢复跟随。不依赖 ScrollEndNotification(dragDetails==null):
  /// 慢速/无惯性拖动结束不触发该通知,原 _userScrolling 标志会卡死不复位。
  void _onScrollStateChanged() {
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.isScrollingNotifier.value) return;
    if (_isAtBottom) _userScrolledAway = false;
  }

  /// chatProvider 状态变化副作用监听器(ref.listen 回调封装)。
  /// initState 创建(在所有被依赖的 controller 之后),dispose cancel timer。
  /// 持有 _didLocateUnread / _loadingHideTimer / _pendingScroll 三个状态字段。
  late final ChatStateListener _stateListener;

  /// 每条消息对应一个 GlobalKey,用于拿 RenderObject 算菜单定位/出屏判定。
  /// 跨职责:菜单 + 未读定位共用,保留在 chat_page。
  final Map<String, GlobalKey> _bubbleKeys = {};

  /// 已播放入场动画的实时消息 id 集合。
  ///
  /// SliverList 懒加载:卡片滚出视口被 dispose,滚回时重建 → 若不加约束,
  /// EnterExpand 会重播动画(旧 SizeTransition 重播导致 ranOut 拉回;现在
  /// FadeTransition 重播导致闪烁)。这里记录"首达已播"的消息,重建时
  /// animateEntry=false 直接显示完整内容,不重播。
  final Set<String> _animatedLiveIds = {};

  /// 长按菜单控制器(状态封装 + 行为注入)。
  /// initState 创建,dispose 释放。内部管理 OverlayEntry / 定位缓存等。
  late final MessageMenuController _menuController;

  /// 多选模式控制器(状态封装 + 行为注入)。
  /// initState 创建。无资源需手动 dispose。
  late final MultiSelectController _multiSelectController;

  /// 会话已读同步控制器(markRead + syncParentConvUnread)。
  /// initState 创建(在 _unreadTracker 之前,被后者依赖:onSyncParentConvUnread
  /// 指向本 controller)。无资源需手动 dispose。
  late final ConvSyncController _convSync;

  /// 输入栏行为控制器(send / pickFile / takePhoto / pickAlbum)。
  /// initState 创建。无资源需手动 dispose。
  late final InputController _inputController;

  /// MessageInputBar 的 GlobalKey,用于 InputController 转发 setSlash 调用。
  /// agent_session 三分支(sessionMeta 已加载/加载中/置灰)互斥,共享同一个 key 安全。
  /// dm/群聊分支不挂此 key(无 slash 能力,且不会与 agent_session 同时挂载)。
  /// initState 末尾用 postFrameCallback 把 currentState.setSlash 绑定到
  /// _inputController.onSetSlash。_MessageInputBarState 是私有类,用 dynamic dispatch。
  final GlobalKey _inputBarKey = GlobalKey();

  /// 跳转引用块 + 高亮 flash + 滚动到底部控制器(状态封装 + 行为注入)。
  /// initState 创建,dispose cancel 高亮 Timer(避免 setState-after-dispose)。
  /// build 读 _jumpController.highlightedMessageId 决定是否包高亮背景。
  late final JumpController _jumpController;

  /// 未读定位控制器(进入会话跳到第一条未读 + 视口可见性判断)。
  /// initState 创建。无资源需手动 dispose。
  late final UnreadLocatorController _unreadLocator;

  /// 已读上报控制器(检查视口内未读 + debounce 同步 server)。
  /// initState 创建(在 _unreadLocator 之后,依赖其 isLocating/isMessageInViewport)。
  /// dispose 释放 debounce timer(在 _unreadLocator 之前)。
  late final UnreadTrackerController _unreadTracker;

  /// 历史消息预加载控制器(滚动 50% 阈值触发 loadMore)。
  /// initState 创建(在 _unreadTracker 之后,依赖 UnreadLocatorController.isLocating)。
  /// 无资源需手动 dispose。
  late final LoadMoreController _loadMoreController;

  /// 双 sliver 滚动物理:initState 创建一次(getLiveEmpty 闭包捕获 ref),
  /// build 引用同一实例,避免每次 rebuild 新建 physics 触发 ScrollPosition 重建抖动。
  late final DualSliverClampingPhysics _physics;

  /// 选区文本缓存（SelectableRegion.onSelectionChanged 收集，供复制读取）。
  String? _selectedText;

  /// 常驻 SelectableRegion 的 key（包整个消息列表，统一选择区）。
  final GlobalKey<SelectableRegionState> _selectionKey =
      GlobalKey<SelectableRegionState>();

  /// 常驻 SelectableRegion 的 focusNode（持久持有，dispose 释放）。
  final FocusNode _selectionFocusNode = FocusNode();

  /// 文件下载服务（下载/打开/取消）。token 在 initState 拿 authProvider 注入。
  late final FileDownloadService _downloadService;

  /// 文件下载控制器(状态封装 + 行为注入)。
  /// initState 创建,dispose 释放。
  late final FileDownloadController _fileController;

  /// 滚动视口的 key，用于拿它的 RenderBox 算可见区域
  /// （已扣除 AppBar 和输入栏，菜单定位/出屏判定用它而非全屏）。
  final GlobalKey _listViewKey = GlobalKey();

  /// 活跃 sliver 的 key(CustomScrollView.center 锚点,正方向原点)。
  final GlobalKey _liveSliverKey = GlobalKey();

  /// 历史 sliver 的 key(leading,负方向延伸)。
  final GlobalKey _historySliverKey = GlobalKey();

  /// 订阅 MESSAGE_CREATE：agent 回复到达时清掉 typing。
  StreamSubscription<WSMessage>? _msgSub;

  /// 缓存 dispose 阶段需要的 notifier / ws 引用。
  late final ConversationListNotifier _convNotifier;
  late final TypingNotifier _typingNotifier;
  late final WebSocketService _ws;
  AgentSessionsNotifier? _sessionsNotifier;

  /// 首屏骨架屏是否已揭开(server 就绪 + 定位稳定后置 true)。
  /// false 期间骨架屏 opacity=1.0 盖住消息区空白锚点。
  bool _isChatReady = false;

  /// 骨架屏淡出动画完成标记。true 后从 widget 树移除骨架屏,释放动画资源。
  bool _skeletonDone = false;

  /// 骨架屏 5 秒超时兜底:避免 server 异常时永久卡在骨架屏。
  Timer? _skeletonTimer;

  /// 打字态(busy/retry 也视作占位)。双 sliver 下 typing 走 trailing SliverToBoxAdapter,
  /// loadMore 走 leading SliverToBoxAdapter,不再烘焙进 itemCount。
  bool _isTyping = false;

  // 斜杠命令状态
  List<SlashCommand> _slashCommands = const [];
  bool _slashSheetOpen = false;
  // TODO(future): 接 SlashHandle.onSideChanged 回调动态同步吸附侧,目前固定 right。
  AttachSide _handleSide = AttachSide.right;

  @override
  void initState() {
    super.initState();
    // scrollview_observer 初始化:SliverObserverController 驱动 SliverViewObserver,
    // 提供跨 sliver 的 jumpTo(index, sliverContext) 定位能力。
    _scrollCtrl = ScrollController(
      onAttach: (position) => position.isScrollingNotifier
          .addListener(_onScrollStateChanged),
      onDetach: (position) => position.isScrollingNotifier
          .removeListener(_onScrollStateChanged),
    );
    _observerController = SliverObserverController(controller: _scrollCtrl)
      ..cacheJumpIndexOffset = false; // IM 经常增删消息，关闭偏移缓存
    _scrollCtrl.addListener(_onScroll);
    _convNotifier = ref.read(conversationProvider.notifier);
    _typingNotifier = ref.read(typingProvider.notifier);
    _convNotifier.setActiveConv(widget.convId);
    final aid = widget.agentId;
    if (aid != null) {
      _sessionsNotifier = ref.read(agentSessionsProvider(aid).notifier);
      _sessionsNotifier!.setActiveConv(widget.convId);
    }
    _ws = ref.read(wsProvider);
    // 文件下载服务：baseUrl + token 注入（同 ApiService / WebSocketService 配置）。
    final api = ref.read(apiProvider);
    final auth = ref.read(authProvider);
    _downloadService = FileDownloadService(
      baseUrl: api.baseUrl,
      token: auth.token ?? '',
    );
    _fileController = FileDownloadController(FileDownloadContext(
      getContext: () => context,
      onSetState: setState,
      isMounted: () => mounted,
      downloadService: _downloadService,
    ));
    // 上报当前会话给服务端（op=3）+ 本地 conversationProvider。
    // 注:op=3 服务端原本用于「跳过未读计数」,但该守卫已移除,所有 agent 消息一律
    // 计未读,client 端在底部时 _convSync.markRead() 归零。op=3 当前主要服务于本地
    // conversationProvider（避免用户在看的会话还闪烁徽章）,服务端仅记录
    // activeConv 状态供后续 participants 模型或其他扩展复用。
    _ws.setActiveConv(widget.convId);
    _msgSub = _ws.messages.where((m) => m.t == 'MESSAGE_CREATE').listen((m) {
      final d = m.d as Map<String, dynamic>?;
      if (d == null) return;
      if (d['conversation_id'] == widget.convId &&
          d['sender_type'] == 'agent') {
        // 聚合卡 silent 建卡（content.silent=true，回合进行中）不清 typing。
        final content = d['content'];
        if (content is Map && content['silent'] == true) return;
        _typingNotifier.clearTyping(widget.convId);
      }
    });
    // 初始化合并偏移量（只在 init 时跑一次，后续靠 listen 更新）
    _refreshExtraItems();
    // 多选模式控制器:把所有外部依赖打包注入。
    // 必须在 _menuController 之前初始化:MessageMenuContext.onEnterSelectionMode
    // 引用 _multiSelectController.enterSelection。
    _multiSelectController = MultiSelectController(MultiSelectContext(
      getContext: () => context,
      ref: ref,
      chatKey: (convId: widget.convId, agentId: widget.agentId),
      onSetState: setState,
    ));
    // 输入栏行为控制器：把所有外部依赖打包注入。
    _inputController = InputController(InputContext(
      getContext: () => context,
      ref: ref,
      chatKey: (convId: widget.convId, agentId: widget.agentId),
      isMounted: () => mounted,
      getNotifier: () => ref.read(
        chatProvider(
          (convId: widget.convId, agentId: widget.agentId),
        ).notifier,
      ),
    ));
    // 跳转引用块 + 高亮 + 滚动到底部控制器:把所有外部依赖打包注入。
    _jumpController = JumpController(JumpContext(
      getContext: () => context,
      ref: ref,
      chatKey: (convId: widget.convId, agentId: widget.agentId),
      onSetState: setState,
      isMounted: () => mounted,
      getScrollCtrl: () => _scrollCtrl,
      getLiveEmpty: () => ref
          .read(chatProvider(
            (convId: widget.convId, agentId: widget.agentId),
          ))
          .liveMessages
          .isEmpty,
      getObserverController: () => _observerController,
      getLiveSliverContext: () => _liveSliverKey.currentContext,
      getHistorySliverContext: () => _historySliverKey.currentContext,
      getBubbleKeys: () => _bubbleKeys,
    ));
    // 未读定位控制器:把所有外部依赖打包注入。
    // onLocateComplete 在定位完成的 PostFrameCallback 里调:预加载一页历史
    // (避免用户下滑立即触顶) + 检查 firstUnread 已在视口内的未读。
    _unreadLocator = UnreadLocatorController(UnreadLocatorContext(
      ref: ref,
      chatKey: (convId: widget.convId, agentId: widget.agentId),
      isMounted: () => mounted,
      getScrollCtrl: () => _scrollCtrl,
      getObserverController: () => _observerController,
      getHistorySliverContext: () => _historySliverKey.currentContext,
      getBubbleKeys: () => _bubbleKeys,
      getListViewKey: () => _listViewKey,
      getContext: () => context,
      onLocateComplete: () {
        final chatKey = (convId: widget.convId, agentId: widget.agentId);
        // 首屏预加载：定位完成后主动拉一页历史。
        // 定位点（firstUnread）是 messages.last（视觉顶部），若不预加载，
        // 用户一下滑就 overdrag 触顶，50% 阈值无空间生效。预加载 100 条
        // 历史后，maxExtent 立即增大，用户下滑到 50% 阈值时正常预加载，
        // 链式生效避免触顶。
        ref.read(chatProvider(chatKey).notifier).loadMoreHistory();
        // 定位完成时 firstUnread 已在视口内（可能短消息密集首屏还有更多未读），
        // 主动检查一次，让浮标数立即反映「已看到 N 条」。
        _unreadTracker.checkUnreadSeen();
        // 定位到历史未读后挂起跟随：程序化 jumpTo 不触发 dragDetails，
        // _userScrolledAway 仍为初始 false，若不置位，骨架屏揭开后下一帧
        // agent 流式 chunk 到达会被流式跟随拉回底部（IM 直觉应停在历史位置
        // 让用户阅读）。复用 _userScrolledAway：用户回底部 / 点浮标跳底 /
        // 发消息滚底时 _onScroll 的 !isScrolling 分支自动复位，跟随恢复。
        _userScrolledAway = true;
        // 有未读定位场景的揭开信号:定位完成后揭开骨架屏。
        _markChatReady();
      },
    ));
    // 会话已读同步控制器:把所有外部依赖打包注入。
    // 必须在 _unreadTracker 之前初始化:UnreadTrackerContext.onSyncParentConvUnread
    // 指向 _convSync.syncParentConvUnread。
    _convSync = ConvSyncController(ConvSyncContext(
      ref: ref,
      convId: widget.convId,
      agentId: widget.agentId,
      getSessionsNotifier: () => _sessionsNotifier,
    ));
    // 已读上报控制器:把所有外部依赖打包注入。
    // 必须在 _unreadLocator 之后初始化:依赖其 isLocating / isMessageInViewport。
    // getSessionsNotifier 返回 _sessionsNotifier(可 null:user-user DM 会话无 agent)。
    _unreadTracker = UnreadTrackerController(UnreadTrackerContext(
      ref: ref,
      chatKey: (convId: widget.convId, agentId: widget.agentId),
      isMounted: () => mounted,
      isLocating: () => _unreadLocator.isLocating,
      isMessageInViewport: _unreadLocator.isMessageInViewport,
      onSyncParentConvUnread: _convSync.syncParentConvUnread,
      getSessionsNotifier: () => _sessionsNotifier,
    ));
    // 历史消息预加载控制器:把所有外部依赖打包注入。
    // 必须在 _unreadTracker 之后初始化:依赖 UnreadLocatorController.isLocating。
    _loadMoreController = LoadMoreController(LoadMoreContext(
      ref: ref,
      chatKey: (convId: widget.convId, agentId: widget.agentId),
      getScrollCtrl: () => _scrollCtrl,
      isLocating: () => _unreadLocator.isLocating,
      getNotifier: () => ref.read(
        chatProvider(
          (convId: widget.convId, agentId: widget.agentId),
        ).notifier,
      ),
    ));
    _physics = DualSliverClampingPhysics(
      getLiveEmpty: () => ref
          .read(chatProvider(
            (convId: widget.convId, agentId: widget.agentId),
          ))
          .liveMessages
          .isEmpty,
    );
    // 长按菜单控制器:把所有外部依赖打包注入。
    // _bubbleKeys / _listViewKey / _selectionKey / _selectedText 跨职责
    // (未读定位 / 滚动 / 选区共用),保留在本 state,通过闭包传入 controller。
    _menuController = MessageMenuController(MessageMenuContext(
      getContext: () => context,
      getListViewKey: () => _listViewKey,
      bubbleGlobalRect: (msgId) => globalRectOf(_bubbleKeys[msgId]),
      getMessages: () => ref
          .read(
            chatProvider((convId: widget.convId, agentId: widget.agentId)),
          )
          .displayMessages,
      getCurrentUserId: () => ref.read(authProvider).user?.id ?? '',
      onCopySelectedOrFull: (msg) async {
        final sel = _selectedText;
        final text = (sel != null && sel.isNotEmpty)
            ? sel
            : extractMessageText(msg);
        if (text.isEmpty) {
          if (mounted) showAppSnackBar(context, '该消息无可复制文本');
          return;
        }
        await Clipboard.setData(ClipboardData(text: text));
        if (mounted) {
          showAppSnackBar(context, '已复制', type: SnackBarType.success);
        }
      },
      onConfirmDelete: _confirmDelete,
      onEnterSelectionMode: _multiSelectController.enterSelection,
      getIsAgentSession: () {
        // convType 异步加载,菜单展示时动态判断(与 build 里 isAgentSession 同口径)。
        final conv = ref
            .read(conversationProvider)
            .where((c) => c.id == widget.convId)
            .firstOrNull;
        if (conv?.isAgentSession ?? false) return true;
        return ref
                .read(chatProvider(
                  (convId: widget.convId, agentId: widget.agentId),
                ))
                .convType ==
            'agent_session';
      },
      onMenuHide: () {
        // 菜单关闭 → 清选区(常驻 SelectableRegion)+ 清选中文本缓存。
        _selectionKey.currentState?.clearSelection();
        _selectedText = null;
      },
      chatKey: (convId: widget.convId, agentId: widget.agentId),
      ref: ref,
    ));
    // 不需要 Bug C initState 兜底：chatProvider 是 autoDispose，重入会话时
    // state 是全新的（_initialize 重新跑），firstUnreadMessageId 从 null→非 null
    // 自然触发 ref.listen (1) 的定位逻辑。
    // 状态监听器:必须在所有被依赖的 controller 之后初始化
    // (jumpController / convSync / unreadLocator / sessionsNotifier / chatObserver)。
    _stateListener = ChatStateListener(ChatStateListenerContext(
      ref: ref,
      convId: widget.convId,
      agentId: widget.agentId,
      chatKey: (convId: widget.convId, agentId: widget.agentId),
      isMounted: () => mounted,
      onSetState: setState,
      getUserScrolledAway: () => _userScrolledAway,
      getScrollCtrl: () => _scrollCtrl,
      getNotifier: () => _notifier,
      getSessionsNotifier: () => _sessionsNotifier,
      getJumpController: () => _jumpController,
      getConvSync: () => _convSync,
      getUnreadLocator: () => _unreadLocator,
      onRefreshExtraItems: _refreshExtraItems,
    ));
    // 拉取命令清单(agent_session 才有意义,失败 silently 跳过)。
    // 注:catalog 异步拉取可能在首帧 build 之后完成,setState 触发 rebuild
    // 后感应线自然出现。早退路径:widget.agentId == null(user-user DM 无 agent)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadSlashCatalog();
    });
    // 绑定 InputController.setSlash 到 MessageInputBar 的 state.setSlash。
    // postFrame 等首帧 build 完成,_inputBarKey.currentState 才存在。
    // 注意:首帧 convType 可能尚未加载(chatProvider 还没拿到 getConversation
    // 响应),此时 build 走非 agent_session 分支,_inputBarKey 不会挂到任何
    // inputBar 上 → currentState == null,_ensureSlashBinding() 早退。
    // 真正的绑定由 build() 末尾的幂等补绑在 convType 加载后的下一帧完成。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureSlashBinding();
    });
    // 骨架屏 5 秒超时兜底:server 异常(isServerInitialized 永不 true)时
    // 强制揭开,避免永久卡在骨架屏。
    _skeletonTimer = Timer(const Duration(seconds: 5), _markChatReady);
  }

  /// 幂等地把 _inputController.onSetSlash 绑定到 _inputBarKey.currentState.setSlash。
  ///
  /// 早退条件(任一满足即返回,保证只绑一次):
  /// 1. onSetSlash 已绑定 —— 避免覆盖已生效的闭包,也防止 agent_session 三分支
  ///    切换时重新换绑(GlobalKey 复用语义下首绑的 state 引用后续仍然有效)。
  /// 2. _inputBarKey.currentState 还未就绪 —— 首帧走非 agent_session 分支,或
  ///    agent_session 的 inputBar 还未挂到 _inputBarKey 上。
  ///
  /// 调用点:initState 的一次性 postFrame + build() 末尾的幂等补绑调度。
  /// 二者都用 `if (onSetSlash == null)` 守卫,真正绑定只会发生一次。
  void _ensureSlashBinding() {
    if (_inputController.onSetSlash != null) return;
    final inputBarState = _inputBarKey.currentState;
    if (inputBarState == null) return;
    // _MessageInputBarState 是私有类,只能 dynamic dispatch 调用其 public setSlash。
    _inputController.onSetSlash = (cmd) {
      (inputBarState as dynamic).setSlash(cmd);
    };
  }

  @override
  void dispose() {
    // 兜底：pending 的 markMessagesRead 立即同步（不等 await，HTTP 在后台完成）。
    // 用户上滑减了未读但还没等 500ms 同步就退出会话，靠这里保证 server 最终一致。
    // 顺序:先 dispose(cancel timer,避免 fire 期间并发 flush),再 flush 同步 server。
    // 必须在 _unreadLocator 之前 dispose(tracker 依赖 locator 的回调注入)。
    _unreadTracker.dispose();
    _unreadTracker.flushPendingReadMsgIds();
    // 状态监听器:cancel loadMore 隐藏 timer,避免 fire 期间 setState-after-dispose。
    _stateListener.dispose();
    // 先释放菜单 controller(移除 Overlay),防止页面退出时菜单 Overlay 残留。
    // 注意:这里走 dispose 而非 hideMessageMenu,避免 onMenuHide 去清已销毁的
    // SelectableRegion state(页面 widget 已在销毁中)。
    _menuController.dispose();
    // cancel 高亮 Timer,避免页面退出后 setState-after-dispose。
    _jumpController.dispose();
    _skeletonTimer?.cancel();
    _skeletonTimer = null;
    _msgSub?.cancel();
    // 释放文件下载控制器(取消所有进行中的下载订阅)。
    _fileController.dispose();
    _convNotifier.setActiveConv(null);
    _sessionsNotifier?.setActiveConv(null);
    // 通知服务端：用户已离开该会话，后续 agent 消息恢复计未读。
    _ws.setActiveConv(null);
    _scrollCtrl.dispose();
    _selectionFocusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    // 双 sliver center 几何下「最新贴底」的目标 px 由 dualSliverBottomTarget 决定:
    // live 非空 → maxScrollExtent;live 空 → max(minScrollExtent, -vd)。
    // loadMore 不在这里触发(改由 _loadMoreController.onScrollNotification 的 50% 阈值处理,
    // 避免定位后链式触发)。
    final pos = _scrollCtrl.position;
    final px = pos.pixels;
    final liveEmpty = ref
        .read(chatProvider((convId: widget.convId, agentId: widget.agentId)))
        .liveMessages
        .isEmpty;
    final bottom = dualSliverBottomTarget(
      minScrollExtent: pos.minScrollExtent,
      maxScrollExtent: pos.maxScrollExtent,
      viewportDimension: pos.viewportDimension,
      liveEmpty: liveEmpty,
    );
    final wasAtBottom = _isAtBottom;
    _isAtBottom = (px - bottom).abs() <= 50;
    // 非拖动/惯性期间,回到底部 50px 内 → 恢复贴底跟随。
    // 拖动中必须保持离开态:用户上滑时 px 仍短暂处于 50px 容差内,若此刻复位,
    // 流式跟随会把视口抢回底部,导致上滑看历史停不住。程序化滚底(jumpTo/animateTo)
    // 不置 _userScrolledAway,到达底部时走这里正常复位。
    // 滚动完全停稳后 px 不再变化,_onScroll 不再触发,由 isScrollingNotifier
    // 回调(_onScrollStateChanged)补一次复位。
    if (_isAtBottom && !_scrollCtrl.position.isScrollingNotifier.value) {
      _userScrolledAway = false;
    }
    if (wasAtBottom != _isAtBottom) {
      // _isAtBottom 变化时触发 rebuild：跳转底部浮标 / 未读浮标的显示条件都依赖
      // !_isAtBottom，不 rebuild 它们不会消失/出现。
      setState(() {});
    }
    if (!wasAtBottom && _isAtBottom) {
      // 用户主动滑到底部时标记已读：清未读浮标 + 分割线。
      // markReadAtBottom 只清 chatState.unreadCount,漏清 conversation[X].unreadCount
      // 会导致列表徽章残留(server 已 0,本地仍 N),退出后看 list 仍显示未读。
      // 对齐 _convSync.markRead() 路径:同步刷 conversationProvider + store。
      ref
          .read(
            chatProvider((
              convId: widget.convId,
              agentId: widget.agentId,
            )).notifier,
          )
          .markReadAtBottom();
      ref.read(conversationProvider.notifier).markReadLocally(widget.convId);
      _sessionsNotifier?.markReadLocally(widget.convId);
      _convSync.syncParentConvUnread();
    }
    // 菜单打开时随滚动动态调整定位或取消。
    _menuController.updateMenuOnScroll();
    // 用 PostFrameCallback 等 ListView rebuild 完成（新进入视口的消息已 build，
    // GlobalKey.currentContext 有效）。否则 _unreadLocator.isMessageInViewport 会因 currentContext
    // 为 null 返 false，浮标数永远不减。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _unreadTracker.checkUnreadSeen();
    });
  }

  /// 滚动通知处理：检测用户主动拖动 + 转发 LoadMoreController 的 50% 阈值加载。
  ///
  /// [ScrollStartNotification] 且 [ScrollNotification.dragDetails] 非空：用户手指
  /// 按下开始拖动 → 退出贴底跟随。程序化滚动(jumpTo/animateTo)与被新内容被动
  /// 顶出均无 dragDetails,不会误标记;复位(回底部恢复跟随)由 _onScroll 的
  /// `!isScrollingNotifier` 分支与 [_onScrollStateChanged] 处理,不依赖
  /// ScrollEndNotification(dragDetails==null)(慢速拖动不触发该通知)。
  bool _handleScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _userScrolledAway = true;
    }
    return _loadMoreController.onScrollNotification(n);
  }

  /// 聚合卡工具折叠组展开/收起时的滚动补偿。
  ///
  /// 同步方案:ToolGroupCard 展开内容始终渲染(heightFactor 控制视觉高度),
  /// 点击时同步测出展开内容真实高度,回调传 [topDelta](= ±高度)。
  /// history sliver 反向列表下,展开内容向上长 → 折叠框 top 上移 topDelta,
  /// 要让视觉锚点不动,offset 需补偿 pixels + topDelta(展开 topDelta<0 往上滚,
  /// 收起 topDelta>0 往下滚)。
  ///
  /// 在同一帧 jumpTo(瞬时):ToolGroupCard 的 setState 与本次 jumpTo 同步排队,
  /// 下一帧 build 时 offset 已就位 + 内容已展开 → 视觉锚点不动、无补间动画、
  /// 无 postFrame 一帧跳变。
  ///
  /// 仅 history sliver 需要补偿:live sliver 正向展开/收起内容自然,补偿会破坏
  /// 原有锚定。由 [isHistory] 区分。
  void _onToolGroupToggle(
      GlobalKey key, bool _, double topDelta, bool isHistory) {
    if (!isHistory || !_scrollCtrl.hasClients) return;
    if (topDelta.abs() < 0.5) return; // 无高度变化,无需补偿
    final pos = _scrollCtrl.position;
    final target =
        (pos.pixels + topDelta)
            .clamp(pos.minScrollExtent, pos.maxScrollExtent);
    _scrollCtrl.jumpTo(target);
  }

  /// 重算打字态(busy/retry 也视作占位,与 typing 共用同一个 trailing 插槽)。
  /// generating 聚合卡存在时抑制气泡:聚合卡自身承载生成状态,无需重复 dots。
  /// agent_session 会话恒不显示气泡:运行时状态已由 AppBar subtitle「灵光涌动...」
  /// + StopBar 红色高亮 + 聚合卡生成状态承载,气泡提示多余。
  void _refreshExtraItems() {
    if (!mounted) return;
    final typing = ref.read(typingProvider)[widget.convId] ?? false;
    final agentStatus = ref.read(agentStatusProvider)[widget.convId];
    final chatState = ref
        .read(chatProvider((convId: widget.convId, agentId: widget.agentId)));
    final live = chatState.liveMessages;
    final hasGeneratingCard = hasGeneratingAggregateCard(live);
    final conv = ref.read(conversationProvider).where(
          (c) => c.id == widget.convId,
        ).firstOrNull;
    final isAgentSession =
        conv?.isAgentSession ?? (chatState.convType == 'agent_session');
    // agent_session 恒不显示气泡;普通会话按 typing/busy 状态 + 聚合卡抑制决定。
    final showBubble = !isAgentSession &&
        (typing || agentStatus != null) &&
        !hasGeneratingCard;
    if (_isTyping != showBubble) {
      _isTyping = showBubble;
      if (mounted) setState(() {});
    }
  }

  /// 标记首屏就绪(server 初始化完成 + 消息定位稳定),触发骨架屏淡出。
  /// 三条揭开信号(5s 超时 / pendingInitialScroll / onLocateComplete)共用,
  /// 避免每处重复写 mounted 守卫 + setState。
  void _markChatReady() {
    if (mounted && !_isChatReady) {
      _isChatReady = true;
      setState(() {});
    }
  }

  ChatNotifier get _notifier => ref.read(
    chatProvider((convId: widget.convId, agentId: widget.agentId)).notifier,
  );

  String get _agentName {
    // 优先用 conversationProvider 的 Conversation(含 type / otherUser 等完整信息)。
    // dm_user_user 会话 agent=null 但 otherUser 有昵称 → 用 displayName 智能分流。
    final conv = ref.watch(
      conversationProvider.select(
        (list) => list.where((c) => c.id == widget.convId).firstOrNull,
      ),
    );
    if (conv != null) {
      // 群聊场景 AppBar title 拼「群名(人数)」,单聊走 displayName。
      // agent_session 排版对齐 dm_user_agent:只显会话名,不拼人数。
      // participants 是 server BatchLoadParticipantSummaries 返的全员摘要,
      // 长度反映群规模。无 participants fallback 走 displayName(防漏)。
      if (conv.isGroup &&
          !conv.isAgentSession &&
          conv.participants.isNotEmpty) {
        final name = conv.displayName;
        return '$name(${conv.participants.length})';
      }
      return conv.displayName;
    }
    // fallback:conversationProvider 还没拉到该会话(agent_session 被 ListForUser 排除)。
    // chatState.convTitle 从 getConversation 拉取,_initialize 首帧后可用。
    final chatState = ref.read(
      chatProvider((convId: widget.convId, agentId: widget.agentId)),
    );
    if (chatState.convTitle != null) {
      return chatState.convTitle!;
    }
    if (widget.agentId == null || widget.agentId!.isEmpty) return '私聊';
    final agent = ref.watch(agentByIdProvider(widget.agentId!));
    return agent?.name ?? '私聊';
  }

  // ============ session meta 状态条 ============
  // 已抽离到 widgets/chat/session_meta_strip.dart(SessionMetaStrip)

  // ============ 长按菜单 ============
  // 已抽离到 widgets/chat/message_menu_controller.dart(MessageMenuController)。
  // 7 个方法(show/hide/update/build/canRecall/computePlacement/dispose) +
  // 3 个字段(_menuEntry / _activeSelectMsgId / _menuPlacement)全部封装在 controller。
  // chat_page 通过 _menuController 转发调用。

  // ============ 跳转 / 高亮 / 滚动到底部 ============
  // 已抽离到 widgets/chat/jump_controller.dart(JumpController)。
  // 4 个方法(jumpToMessage/scrollToMessageIndex/highlightMessage/scrollToBottom)
  // + 高亮目标 id 状态全部封装在 controller,chat_page 通过
  // _jumpController 转发调用。

  /// 删除/撤回确认(单条/批量共用)。弹 showAppDialog 二次确认 → 调 provider。
  /// recall=true 走撤回(scope=recall,双向删除);默认 hide(对自己隐藏)。
  /// 菜单(单条)和多选模式(批量)共用此方法,作协调者,保留在 chat_page。
  Future<void> _confirmDelete(List<String> ids, {bool recall = false}) async {
    if (ids.isEmpty) return;
    showAppDialog(
      context: context,
      title: recall ? '撤回消息' : '删除消息',
      content: Text(
        recall
            ? '确定撤回这条消息吗?'
            : (ids.length == 1 ? '确定删除这条消息吗?' : '确定删除 ${ids.length} 条消息吗?'),
      ),
      confirmText: recall ? '撤回' : '删除',
      onConfirm: () async {
        final wasSelectionMode = _multiSelectController.isSelectionMode;
        try {
          await _notifier.deleteMessages(
            ids,
            scope: recall ? 'recall' : 'hide',
          );
          // 清理已删消息的 GlobalKey(防长期会话 Map 无限增长)
          _bubbleKeys.removeWhere((k, _) => ids.contains(k));
          if (!mounted) return;
          // 删除成功后若是多选模式,清空选中并退出
          if (wasSelectionMode) {
            _multiSelectController.exitSelection();
          }
        } catch (_) {
          // provider 失败已回滚,UI 层提示。多选模式不退出(让用户重试)。
          if (mounted) {
            showAppSnackBar(
              context,
              recall ? '撤回失败,请重试' : '删除失败,请重试',
              type: SnackBarType.error,
            );
          }
        }
      },
    );
  }

  Future<void> _showModelPicker(
    BuildContext context, WidgetRef ref,
    ({String convId, String? agentId}) chatKey,
  ) async {
    if (chatKey.agentId == null) return;
    try {
      final models = await ref.read(apiProvider).getAgentModels(chatKey.agentId!);
      if (!context.mounted) return;
      if (models.isEmpty) {
        showAppSnackBar(context, '暂无可选模型', type: SnackBarType.info);
        return;
      }
      final currentState = ref.read(chatProvider(chatKey));
      final selected = await ModelPickerDialog.show(
        context: context,
        models: models,
        currentOverride: currentState.modelOverride,
        currentSessionMeta: currentState.sessionMeta,
      );
      if (selected != null) {
        ref.read(chatProvider(chatKey).notifier).selectModel(selected);
      }
    } catch (e) {
      if (!context.mounted) return;
      showAppSnackBar(context, '模型列表加载失败', type: SnackBarType.error);
    }
  }

  /// 模式选择:清单驱动(plugin 上报 AGENT_MODES)。
  /// 空清单(老插件未上报)回退 build↔plan 二值切换(OC 兼容期)。
  Future<void> _showModePicker(
    BuildContext context, WidgetRef ref,
    ({String convId, String? agentId}) chatKey,
  ) async {
    final chatNotifier = ref.read(chatProvider(chatKey).notifier);
    if (chatKey.agentId != null) {
      final modes =
          await ref.read(agentModesProvider(chatKey.agentId!).future);
      if (modes.isNotEmpty && context.mounted) {
        final chatState = ref.read(chatProvider(chatKey));
        final selected = await ModePickerDialog.show(
          context: context,
          modes: modes,
          currentMode: chatState.modeOverride ?? chatState.sessionMeta?.mode,
        );
        if (selected != null) chatNotifier.selectMode(selected);
        return;
      }
    }
    chatNotifier.toggleMode();
  }

  Future<void> _loadSlashCatalog() async {
    if (widget.agentId == null) return;
    try {
      final api = ref.read(apiProvider);
      final cmds = await api.getAgentSlashCatalog(widget.agentId!);
      if (mounted) setState(() => _slashCommands = cmds);
    } catch (e) {
      // fail silently — 感应线不显示即可,不打扰用户
      debugPrint('[chatPage] loadSlashCatalog 失败: $e');
    }
  }

  // ============ build ============

  @override
  Widget build(BuildContext context) {
    final chatKey = (convId: widget.convId, agentId: widget.agentId);
    final chatState = ref.watch(chatProvider(chatKey));
    // 关键节点日志（只打印关键状态，避免每次 build 刷屏）
    final px = _scrollCtrl.hasClients ? _scrollCtrl.position.pixels : -1;
    final maxExt = _scrollCtrl.hasClients ? _scrollCtrl.position.maxScrollExtent : -1;
    debugPrint(
      '[build] messages=${chatState.displayMessages.length}, '
      'firstUnread=${chatState.firstUnreadMessageId}, '
      'hasMore=${chatState.hasMore}, '
      'showUnreadSeparator=${chatState.showUnreadSeparator}, '
      'unreadCount=${chatState.unreadCount}, '
      '_pendingScroll=${_stateListener.pendingScroll}, '
      '_didLocateUnread=${_stateListener.didLocateUnread}, '
      'scrollPx=$px, maxExt=$maxExt',
    );
    // 监听状态变化，处理三类副作用：
    // (1) 未读定位：firstUnreadMessageId 从 null→非null（_initialize 完成）时触发定位。
    //     用 _didLocateUnread 标记防重复（_initialize 只会成功一次）。
    // (2) 新消息计数：messages 长度增长时，按 _isAtBottom 决定增哪个计数器。
    // (3) pendingScroll：自己发的消息 echo 回来时滚到底部。
    // 实现:详见 widgets/chat/chat_state_listener.dart(副作用逻辑封装)。
    ref.listen(
      chatProvider(chatKey),
      (prev, next) {
        _stateListener.onChatStateChanged(prev, next);
        // 消息列表变化(含聚合卡创建)→ 重算 TypingBubble 插槽显隐:
        // 聚合卡创建后应立刻隐藏 busy 气泡,不等 typing/status 下次触发。
        _refreshExtraItems();
      },
    );

    // 监听打字态 + hasMore 变化，合并更新偏移量（避免两路 provider 索引抖动）
    ref.listen(typingProvider, (_, __) => _refreshExtraItems());
    // agent 状态(busy/retry/idle)变化同样需要重算 TypingBubble 插槽显隐
    ref.listen(agentStatusProvider, (_, __) => _refreshExtraItems());

    final agentName = _agentName;
    // 当前 user id,用于判断消息方向（user-user 会话双方 senderType 都是 'user'，
    // 必须用 senderId 区分自己 vs 对方）。
    final currentUserId =
        ref.watch(authProvider.select((s) => s.user?.id)) ?? '';
    // 在线状态/打字指示器仅 dm_user_agent 场景显示(agent 才有在线状态概念)。
    // conv 加载后用 conv.type 校验,避免 widget.agentId 是 user senderId 占位误传
    // (通知跳转 user-user / 群聊场景 senderId 也会塞 agentId 字段作占位)。
    // conv 还没 load 时(如刚 push 的 initState 阶段)fallback widget.agentId 兜底。
    final convForStatus = ref.watch(
      conversationProvider.select(
        (list) => list.where((c) => c.id == widget.convId).firstOrNull,
      ),
    );
    final isDmWithAgent = convForStatus != null
        ? convForStatus.type == 'dm_user_agent' && convForStatus.agent != null
        : (widget.agentId != null && widget.agentId!.isNotEmpty);
    // agentId 优先用 conv.agent.id(server 权威),早期 fallback widget.agentId
    final agentIdForStatus = convForStatus?.agent?.id ?? widget.agentId;
    final showStatus =
        isDmWithAgent &&
        agentIdForStatus != null &&
        agentIdForStatus.isNotEmpty;
    // dm_user_user 单聊校验好友关系:删除好友后置灰输入栏 + 顶部条幅提示。
    // dm_user_agent / 群聊不校验(agent 单聊 server 不要求 friend,群聊用 participants 表)。
    final isDmUserUser = convForStatus?.type == 'dm_user_user';
    final otherUsername = convForStatus?.otherUser?.username ?? '';
    final friendList = ref.watch(friendListProvider);
    final canSend =
        !isDmUserUser ||
        (otherUsername.isNotEmpty && friendList.isFriend(otherUsername));
    // typing 按 conversation_id 路由(对齐 server 新协议)
    final agentStatus = showStatus
        ? ref.watch(agentByIdProvider(agentIdForStatus))?.status
        : null;
    // agent_session 查 agent.type 决定是否显 AgentBadge(opencode agent 才显)
    final isAgentSession = convForStatus?.isAgentSession ??
        (chatState.convType == 'agent_session');
    final agentTypeForBadge = isAgentSession &&
            agentIdForStatus != null
        ? ref.watch(agentByIdProvider(agentIdForStatus))?.type
        : null;

    if (_stateListener.pendingScroll &&
        (chatState.displayMessages.isNotEmpty || _isTyping)) {
      _stateListener.pendingScroll = false;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _jumpController.scrollToBottom(),
      );
    }

    if (_stateListener.pendingInitialScroll) {
      _stateListener.pendingInitialScroll = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scrollCtrl.hasClients) {
          final pos = _scrollCtrl.position;
          _scrollCtrl.jumpTo(dualSliverBottomTarget(
            minScrollExtent: pos.minScrollExtent,
            maxScrollExtent: pos.maxScrollExtent,
            viewportDimension: pos.viewportDimension,
            liveEmpty: chatState.liveMessages.isEmpty,
          ));
          // jumpTo 是瞬时跳转(非 animateTo),完成后立即揭开骨架屏。
          // 无未读定位场景的揭开信号。
          // 显式复位 _userScrolledAway(初始为 true 防抢跑):无未读场景用户
          // 进入即应贴最新消息,跟随恢复。显式复位不依赖 _onScroll 的时序,
          // 与 onLocateComplete 的显式保持 true 形成两条路径的清晰对照。
          _userScrolledAway = false;
          _markChatReady();
        }
      });
    }

    // subtitle 渲染规则:
    // - dm_user_agent: AppBar 副标题显在线/离线/正在输入
    // - agent_session: 不在 AppBar 显,改在输入框下方状态条(见 ChatInputBar middleSlot)
    // - 其他: null（不渲染）
    final Widget? subtitle;
    if (isAgentSession) {
      // agent_session 会话:按 agent_status_provider 实时状态显 busy/retry 提示。
      // 用 select 只订阅本 conv 的状态,避免其他 conv 变化触发无谓 rebuild。
      final agentStatus = ref.watch(
        agentStatusProvider.select((s) => s[widget.convId]),
      );
      if (agentStatus == null) {
        subtitle = null;
      } else if (agentStatus.type == AgentStatusType.busy) {
        subtitle = const ShimmerText(
          text: '灵光涌动...',
          baseColor: Color(0xFF07C160),
          style: TextStyle(fontSize: 12),
        );
      } else if (agentStatus.type == AgentStatusType.retry) {
        subtitle = ShimmerText(
          text: '重试中(第 ${agentStatus.attempt} 次)...',
          baseColor: const Color(0xFFE53935),
          style: const TextStyle(fontSize: 12),
        );
      } else {
        // 兜底:未来扩展 AgentStatusType 时显式置 null,避免 subtitle 未赋值。
        subtitle = null;
      }
    } else if (!showStatus) {
      subtitle = null;
    } else {
      final text = _isTyping
          ? '对方正在输入...'
          : (agentStatus == AgentStatus.online ? '在线' : '离线');
      final color = (_isTyping || agentStatus == AgentStatus.online)
          ? const Color(0xFF07C160)
          : const Color(0xFF999999);
      subtitle = Text.rich(
        TextSpan(
          text: text,
          style: TextStyle(fontSize: 12, color: color),
        ),
      );
    }

    final appBar = ChatAppBar(
      selectionMode: _multiSelectController.isSelectionMode,
      selectedCount: _multiSelectController.selectedCount,
      onExitSelection: _multiSelectController.exitSelection,
      agentName: agentName,
      subtitle: subtitle,
      showBadge: (convForStatus?.isUserAgentDM ?? false) ||
          (isAgentSession &&
              AgentCategory.supportsMultiSession(agentTypeForBadge ?? '')),
      badgeType: convForStatus?.agent?.type ?? agentTypeForBadge ?? '',
      onDetailTap: () => context.push('/conversations/${widget.convId}/detail'),
    );

    // 异步 convType 加载场景补绑:首帧 chatState.convType 为空(初始 ChatState)
    // → build 走非 agent_session 分支 → _inputBarKey 未挂到任何 inputBar 上
    // → initState 一次性 postFrame 拿到 currentState == null → onSetSlash 未绑定。
    // 后续 chatProvider 拉 getConversation 返回,convType 更新为 'agent_session'
    // 触发 rebuild → 走 agent_session 分支,inputBar 挂到 _inputBarKey 上,state 就绪。
    // 这里幂等补绑:仅在 onSetSlash 仍未绑定时安排下一帧再试一次。已绑定时早退,
    // 不会重复注册 postFrame,正常流程只触发一次。
    if (_inputController.onSetSlash == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureSlashBinding();
      });
    }

    // 两 sliver 共用的 itemBuilder 上下文。typing 移到 trailing SliverToBoxAdapter,
    // 消息气泡不再需要 isTyping/isAgentBubble,固定 false。
    final itemCtx = ChatMessageItemBuildContext(
      chatState: chatState,
      currentUserId: currentUserId,
      convForStatus: convForStatus,
      bubbleKeys: _bubbleKeys,
      isTyping: false,
      isAgentBubble: false,
      menuController: _menuController,
      multiSelectController: _multiSelectController,
      fileController: _fileController,
      jumpController: _jumpController,
      ref: ref,
      onToolGroupToggle: _onToolGroupToggle,
    );
    // history sliver(反向列表):折叠展开需滚动补偿,isHistorySliver=true。
    // live sliver(正向):展开自然向下,无需补偿,用默认 false。
    final historyItemCtx = itemCtx.copyWith(isHistorySliver: true);

    // PopScope:多选模式拦截返回键(优先退出多选,而非离开页面)。
    // 状态栏跟随 AppBar 模式:普通模式白底深色图标;多选模式深色底白色图标。
    final selectionMode = _multiSelectController.isSelectionMode;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: selectionMode
          ? SystemUiOverlayStyle.dark.copyWith(
              statusBarColor: const Color(0xFF2A2A2A),
            )
          : SystemUiOverlayStyle.light.copyWith(
              statusBarColor: Colors.white,
              systemNavigationBarColor: Colors.white,
            ),
      child: PopScope(
      canPop: !_multiSelectController.isSelectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _multiSelectController.isSelectionMode) {
          _multiSelectController.exitSelection();
        } else if (!didPop && _slashSheetOpen) {
          // 优先关闭 slash sheet
          setState(() => _slashSheetOpen = false);
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFEDEDED),
        appBar: appBar,
        body: Stack(
          children: [
            Column(
          children: [
            // dm_user_user 删除好友后顶部条幅提示(其他场景 canSend=true 不显示)
            if (!canSend) const FriendDeletedBanner(),
            Expanded(
              // 始终挂载 SelectableRegion + SliverViewObserver + CustomScrollView，
              // 让 SliverViewObserver 在 initState 后立即注册 PostFrameCallback 填充
              // sliverContexts。loading 与空会话提示作为 overlay 叠加在 Stack 中。
              // 修复 Bug A：原来 messages.isEmpty 时整个滚动视图被替换成 Center(Text)，
              // SliverViewObserver 首次挂载滞后于 jumpTo 的 PostFrameCallback，
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
                      onNotification: _handleScrollNotification,
                      child: SliverViewObserver(
                        controller: _observerController,
                        sliverContexts: () => [
                          _historySliverKey.currentContext,
                          _liveSliverKey.currentContext,
                        ].whereType<BuildContext>().toList(),
                        child: CustomScrollView(
                          key: _listViewKey,
                          controller: _scrollCtrl,
                          center: _liveSliverKey,
                          physics: _physics,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          slivers: [
                            if (chatState.hasMore)
                              SliverToBoxAdapter(
                                child: LoadMoreIndicator(
                                  isLoading: chatState.isLoadingMore,
                                ),
                              ),
                            if (chatState.historyMessages.isNotEmpty)
                              SliverList(
                                key: _historySliverKey,
                                delegate: SliverChildBuilderDelegate(
                                  (ctx, i) => ChatMessageItemBuilder.buildMessage(
                                    ctx,
                                    chatState.historyMessages[i],
                                    historyItemCtx,
                                    olderNeighbor:
                                        (i + 1 <
                                                chatState
                                                    .historyMessages.length)
                                            ? chatState
                                                .historyMessages[i + 1]
                                            : null,
                                  ),
                                  childCount:
                                      chatState.historyMessages.length,
                                ),
                              ),
                            SliverList(
                              key: _liveSliverKey,
                              delegate: SliverChildBuilderDelegate(
                                (ctx, i) {
                                  final liveMsg = chatState.liveMessages[i];
                                  // 首达(集合里没有该 id)才播入场动画并记录;
                                  // 滚动重建(集合已有)不重播,避免卡片闪烁。
                                  final animateEntry =
                                      _animatedLiveIds.add(liveMsg.id);
                                  final item =
                                      ChatMessageItemBuilder.buildMessage(
                                    ctx,
                                    liveMsg,
                                    itemCtx,
                                    olderNeighbor: (i > 0)
                                        ? chatState.liveMessages[i - 1]
                                        : (chatState
                                                .historyMessages.isNotEmpty
                                            ? chatState.historyMessages.first
                                            : null),
                                    animateEntry: animateEntry,
                                  );
                                  // live 首条顶部加 8px 留白:首次进入/发消息贴底后,
                                  // 首条消息不直接顶到视口上沿(Center 锚点对齐导致)。
                                  // 滚动后首条移出视口,间距自然消失,不影响消息行距。
                                  if (i == 0) {
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: item,
                                    );
                                  }
                                  return item;
                                },
                                childCount: chatState.liveMessages.length,
                              ),
                            ),
                            if (_isTyping)
                              const SliverToBoxAdapter(
                                child: TypingBubble(),
                              ),
                          ],
                        ),
                      ),
                    ), // NotificationListener<ScrollNotification>
                    Positioned.fill(
                      child: ChatListOverlays(
                        chatKey: chatKey,
                        loadingHideTimerActive:
                            _stateListener.loadingHideTimerActive,
                        isTyping: _isTyping,
                        isAtBottom: _isAtBottom,
                        onScrollToBottom: _jumpController.scrollToBottom,
                        onJumpToBottom: _notifier.jumpToBottom,
                      ),
                    ),
                    // 感应线:放在消息列表区域内,拖动天然不会进入底部输入框。
                    // 仅在 agent_session + 命令清单非空时显示。
                    if (chatState.convType == 'agent_session' &&
                        _slashCommands.isNotEmpty)
                      SlashHandle(
                        visible: true,
                        onTrigger: () =>
                            setState(() => _slashSheetOpen = true),
                        onSideChanged: (side) =>
                            setState(() => _handleSide = side),
                      ),
                    // 骨架屏:server 就绪 + 定位稳定前盖住双 sliver 空白锚点。
                    // Positioned.fill 只盖消息区(Expanded),输入栏始终可见。
                    // 淡出完成后 _skeletonDone=true 移除,释放动画资源。
                    if (!_skeletonDone)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedOpacity(
                            opacity: _isChatReady ? 0.0 : 1.0,
                            duration: const Duration(milliseconds: 200),
                            onEnd: () {
                              if (_isChatReady && mounted) {
                                setState(() => _skeletonDone = true);
                              }
                            },
                            child: const ColoredBox(
                              color: Color(0xFFEDEDED),
                              child: ChatLoadingSkeleton(),
                            ),
                          ),
                        ),
                      ),
                  ], // children of Stack
                ), // Stack
              ), // SelectableRegion
            ),
            // 多选模式优先:所有会话类型(含 agent_session)统一显示底部操作栏。
            // agent_session 的 strip/mode bar/输入栏在多选期间不渲染,避免操作栏被遮挡。
            if (_multiSelectController.isSelectionMode)
              SelectionBottomBar(
                selectedCount: _multiSelectController.selectedCount,
                onBatchCopy: _multiSelectController.batchCopy,
                onConfirmDelete: () =>
                    _confirmDelete(_multiSelectController.selectedIdsList),
              )
            else if (chatState.convType == 'agent_session' && chatState.sessionMeta != null)
              Stack(
                children: [
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // strip: 顶部分割线 + 内容 + 底部分割线
                      Container(
                        color: Colors.white,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(height: 0.5, color: const Color(0xFFE5E5E5)),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: SessionMetaStrip(
                                      meta: chatState.sessionMeta!,
                                      modeOverride: chatState.modeOverride,
                                      onModeTap: () =>
                                          _showModePicker(context, ref, chatKey),
                                      modelOverride: chatState.modelOverride,
                                      onModelTap: () => _showModelPicker(context, ref, chatKey),
                                    ),
                                  ),
                                  StopBar(
                                    isGenerating: ref.watch(
                                      agentStatusProvider.select((s) => s[widget.convId]),
                                    ) != null,
                                    onTap: () => ref.read(apiProvider).abortGeneration(widget.convId),
                                  ),
                                ],
                              ),
                            ),
                            Container(height: 0.5, color: const Color(0xFFF0F0F0)),
                            // 环境信息条:agent 工作目录(从 conversations.directory
                            // 一级列,不再读 session_meta.cwd) + git 分支
                            Align(
                              alignment: Alignment.centerLeft,
                              child: EnvMetaStrip(
                                cwd: chatState.directory,
                                gitBranch: chatState.sessionMeta?.gitBranch,
                                tokensTotal: chatState.sessionMeta?.tokensTotal,
                                contextUsed: chatState.sessionMeta?.contextUsed,
                                contextLimit: chatState.sessionMeta?.contextLimit,
                                onTapCwd: chatKey.agentId == null
                                    ? null
                                    : () => openFileBrowser(
                                          context,
                                          agentId: chatKey.agentId!,
                                          convId: chatKey.convId,
                                          cwd: chatState.directory,
                                        ),
                                onTapGitBranch: chatKey.agentId == null
                                    ? null
                                    : () => GoRouter.of(context).push(
                                          '/session-diff/${chatKey.agentId}/${chatKey.convId}',
                                        ),
                              ),
                            ),
                            Container(height: 0.5, color: const Color(0xFFF0F0F0)),
                          ],
                        ),
                      ),
                      // 输入栏
                      ChatInputBar(
                        inputBarKey: _inputBarKey,
                        inputController: _inputController,
                        chatKey: (convId: widget.convId, agentId: widget.agentId),
                        onSendSlash: (name, args) {
                          ref
                              .read(chatProvider(chatKey).notifier)
                              .sendSlash(name, args);
                        },
                      ),
                    ],
                  ),
                  // 左侧模式竖线贯穿 strip + 输入栏
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 4,
                        color: (chatState.modeOverride ?? chatState.sessionMeta!.mode)
                                .toLowerCase() == 'plan'
                            ? const Color(0xFFF4A742)
                            : const Color(0xFF597BFF),
                      ),
                    ),
                  ),
                ],
              )
            else if (chatState.convType == 'agent_session' && chatState.sessionMeta == null)
              // agent_session 加载中：只有输入栏
              canSend
                  ? ChatInputBar(
                      inputBarKey: _inputBarKey,
                      inputController: _inputController,
                      chatKey: (convId: widget.convId, agentId: widget.agentId),
                      onSendSlash: (name, args) {
                        ref
                            .read(chatProvider(chatKey).notifier)
                            .sendSlash(name, args);
                      },
                    )
                  : IgnorePointer(
                      ignoring: true,
                      child: Opacity(
                        opacity: 0.4,
                        child: ChatInputBar(
                          inputBarKey: _inputBarKey,
                          inputController: _inputController,
                          chatKey: (
                            convId: widget.convId,
                            agentId: widget.agentId,
                          ),
                          onSendSlash: (name, args) {
                            ref
                                .read(chatProvider(chatKey).notifier)
                                .sendSlash(name, args);
                          },
                        ),
                      ),
                    )
            else
              // 非 agent_session
              _multiSelectController.isSelectionMode
                  ? SelectionBottomBar(
                      selectedCount: _multiSelectController.selectedCount,
                      onBatchCopy: _multiSelectController.batchCopy,
                      onConfirmDelete: () =>
                          _confirmDelete(_multiSelectController.selectedIdsList),
                    )
                  : canSend
                      ? ChatInputBar(
                          inputController: _inputController,
                          chatKey: (convId: widget.convId, agentId: widget.agentId),
                        )
                      : IgnorePointer(
                          ignoring: true,
                          child: Opacity(
                            opacity: 0.4,
                            child: ChatInputBar(
                              inputController: _inputController,
                              chatKey: (
                                convId: widget.convId,
                                agentId: widget.agentId,
                              ),
                            ),
                          ),
                        ),
          ],
        ), // Column(原 body 主内容)
            // 命令面板(SlashCommandSheet)
            if (_slashSheetOpen)
              SlashCommandSheet(
                commands: _slashCommands,
                side: _handleSide,
                onClose: () => setState(() => _slashSheetOpen = false),
                onSelected: (cmd) {
                  setState(() => _slashSheetOpen = false);
                  _inputController.setSlash(cmd);
                },
              ),
          ],
        ), // Stack(body)
      ), // Scaffold
      ), // PopScope
    ); // AnnotatedRegion
  }
}

