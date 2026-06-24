import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import '../models/agent.dart' show AgentStatus;
import '../models/message.dart' show ChatMessage;
import '../models/msg_type.dart';
import '../models/ws_message.dart' show WSMessage;
import '../providers/agent_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart' show ChatNotifier, chatProvider, wsProvider;
import '../providers/conversation_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/typing_provider.dart';
import '../services/websocket_service.dart';
import '../widgets/message_bubble.dart' show MessageBubble, formatTimestamp;
import '../widgets/message_context_menu.dart';
import '../widgets/message_input_bar.dart';
import '../widgets/avatar_picker.dart' show defaultAssetPickerConfig;
import '../widgets/typing_bubble.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';

const _imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp'};

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
    _scrollCtrl.addListener(_onScroll);
    _convNotifier = ref.read(conversationProvider.notifier);
    _typingNotifier = ref.read(typingProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) => _markRead());
    _convNotifier.setActiveConv(widget.convId);
    _ws = ref.read(wsProvider);
    // 上报当前会话给服务端（op=3）：agent 发消息时该会话不计未读。
    // 与本地 _convNotifier.setActiveConv 互补：本地管 WS 收消息时的乐观计数，
    // 服务端管 unread_count 持久值（列表刷新/多端一致依赖它）。
    _ws.setActiveConv(widget.convId);
    _msgSub = _ws.messages
        .where((m) => m.t == 'MESSAGE_CREATE')
        .listen((m) {
      final d = m.d as Map<String, dynamic>?;
      if (d == null) return;
      if (d['conversation_id'] == widget.convId &&
          d['sender_type'] == 'agent') {
        _typingNotifier.clearTyping(widget.agentId);
      }
    });
  }

  @override
  void dispose() {
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
    if (_scrollCtrl.position.pixels >
        _scrollCtrl.position.maxScrollExtent - 100) {
      _notifier.loadMore();
    }
    // 菜单打开时随滚动动态调整定位或取消。
    _updateMenuOnScroll();
  }

  void _doScrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.jumpTo(0);
  }

  Future<void> _markRead() async {
    ref.read(conversationProvider.notifier).markReadLocally(widget.convId);
    try {
      await ref.read(apiProvider).markConversationRead(widget.convId);
    } catch (_) {
      // 静默：markRead 失败不影响聊天，下次进入会重试
    }
  }

  ChatNotifier get _notifier =>
      ref.read(chatProvider((convId: widget.convId, agentId: widget.agentId)).notifier);

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
    final ctx = _bubbleKeys[msgId]?.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;

    final rect = Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(Offset(box.size.width, box.size.height)),
    );

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
    final top = desiredTop.clamp(
      viewport.top,
      viewport.bottom - kMenuHeight,
    );

    // 水平:菜单居中于消息中心,clamp 不超可见区左右。
    final left = (rect.center.dx - kMenuWidth / 2)
        .clamp(viewport.left + 8, viewport.right - kMenuWidth - 8);
    // 三角指向消息中心:菜单内 x = 消息中心 - 菜单左缘
    final tailOffsetX = (rect.center.dx - left)
        .clamp(kMenuTailHalfWidth, kMenuWidth - kMenuTailHalfWidth);

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
    return ref.read(chatProvider(chatKey));
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('该消息无可复制文本'),
              duration: Duration(seconds: 1)),
        );
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
      );
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
    final texts = chatState
        .where((m) => _selectedIds.contains(m.id))
        .map(_extractText)
        .where((t) => t.isNotEmpty)
        .join('\n');
    if (texts.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('选中的消息无可复制文本'),
              duration: Duration(seconds: 1)),
        );
      }
      return;
    }
    await Clipboard.setData(ClipboardData(text: texts));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
      );
    }
  }

  /// 删除确认(单条/批量共用)。弹 AlertDialog 二次确认 → 调 provider 乐观删除。
  Future<void> _confirmDelete(List<String> ids) async {
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: Text(ids.length == 1
            ? '确定删除这条消息吗?'
            : '确定删除 ${ids.length} 条消息吗?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFFA5151)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('删除失败,请重试')),
        );
      }
    }
  }

  // ============ build ============

  @override
  Widget build(BuildContext context) {
    final chatKey = (convId: widget.convId, agentId: widget.agentId);
    ref.listen(
      chatProvider(chatKey),
      (prev, next) {
        if (next.isEmpty) return;
        if (prev == null || prev.isEmpty || next.first.id != prev.first.id) {
          _pendingScroll = true;
        }
      },
    );

    final chatState = ref.watch(chatProvider(chatKey));
    final agentName = _agentName;
    final isTyping =
        ref.watch(typingProvider.select((m) => m[widget.agentId] ?? false));
    final agentStatus = ref.watch(agentByIdProvider(widget.agentId))?.status;

    if (_pendingScroll && (chatState.isNotEmpty || isTyping)) {
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
                Text(agentName,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.normal)),
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
              child: (chatState.isEmpty && !isTyping)
                  ? const Center(child: Text('发送消息开始对话'))
                  // 常驻 SelectableRegion 包整个消息列表：统一选择区，焦点集中。
                  // 利用 SDK 内置长按选词路径(_selectWordAt)，落点选词+自动拉杆。
                  // MessageBubble 的 Listener 长按弹菜单与之并存(不抢 arena)。
                  // onSelectionChanged 缓存选区文本，供菜单"复制"读取。
                  : SelectableRegion(
                      key: _selectionKey,
                      focusNode: _selectionFocusNode,
                      // materialTextSelectionHandleControls：它是 TextSelectionHandleControls，
                      // buildHandle 复用父类水滴拉杆（保留），buildToolbar 返回空。
                      // 配合 contextMenuBuilder 返回空 → 彻底禁掉系统工具栏(cut/copy/paste/selectAll)，
                      // 拉杆/选中高亮不受影响（由 buildHandle 渲染）。
                      selectionControls: materialTextSelectionHandleControls,
                      contextMenuBuilder: (context, state) =>
                          const SizedBox.shrink(),
                      onSelectionChanged: (c) =>
                          _selectedText = c?.plainText,
                      child: ListView.builder(
                      key: _listViewKey,
                      reverse: true,
                      controller: _scrollCtrl,
                      // 拖拽列表(离开输入框操作)收键盘
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      itemCount: chatState.length + (isTyping ? 1 : 0),
                      itemBuilder: (_, i) {
                        if (isTyping && i == 0) {
                          return const TypingBubble();
                        }
                        final msgIndex = isTyping ? i - 1 : i;
                        final msg = chatState[msgIndex];
                        final showTime = msgIndex == chatState.length - 1 ||
                            msg.createdAt
                                    .difference(
                                        chatState[msgIndex + 1].createdAt)
                                    .inMinutes
                                    .abs() >=
                                5;

                        // 每条消息一个 GlobalKey,用于拿 RenderObject 算菜单定位/出屏判定。
                        final bubbleKey = _bubbleKeys.putIfAbsent(
                            msg.id, () => GlobalKey());
                        final bubble = MessageBubble(
                          key: bubbleKey,
                          message: msg,
                          isMe: msg.senderType == 'user',
                          baseUrl: ref.read(settingsProvider),
                          token: ref.read(authProvider).token ?? '',
                          selectionMode: _selectionMode,
                          selected: _selectedIds.contains(msg.id),
                          onLongPressStart: _selectionMode
                              ? null
                              : (details) => _showMessageMenu(msg),
                          onTapSelect:
                              _selectionMode ? () => _toggleSelect(msg.id) : null,
                        );

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (showTime)
                              Center(
                                child: Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Text(
                                    formatTimestamp(msg.createdAt),
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF999999)),
                                  ),
                                ),
                              ),
                            // 菜单改用绝对定位(锚钉效果),不再需要 LayerLink/follower。
                            bubble,
                          ],
                        );
                      },
                    ), // ListView.builder
                    ), // SelectableRegion
            ),
            if (_selectionMode) _buildSelectionBottomBar() else _buildInputBar(),
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
              color: hasSelection
                  ? const Color(0xFFFA5151)
                  : Colors.grey,
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

      final ext = file.path!.toLowerCase().substring(file.path!.lastIndexOf('.'));
      final msgType = _imageExts.contains(ext) ? MsgType.image : MsgType.file;
      _notifier.sendFile(fileId, msgType);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败: $e')),
        );
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法读取文件')),
        );
      }
      return;
    }
    try {
      final api = ref.read(apiProvider);
      final fileId = await api.uploadFile(file.path);
      _notifier.sendFile(fileId, msgType);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传失败: $e')),
        );
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
  int get hashCode =>
      Object.hash(left, top, tailOffsetX, pointDown);
}
