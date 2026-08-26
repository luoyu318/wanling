import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/providers/agent_status_provider.dart' show agentStatusProvider;
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/chat_state.dart';
import 'package:wanling_core/providers/conversation_provider.dart' show conversationProvider;
import 'package:wanling_core/providers/typing_provider.dart' show typingProvider;
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/utils/gallery_image.dart';
import '../../widgets/image_viewer.dart';
import '../../widgets/chat/typing_bubble.dart';

/// 桌面消息列表:单列表 oldest-first 贴底(chat-single-list 重构结论,不用 reverse:true)。
///
/// - 进会话滚到底(maxScrollExtent,postFrame 兜底);
/// - 流式 delta / 新消息到达时,用户在底部(px >= maxScrollExtent - 50)才跟随滚底;
/// - 上下文分页:列表头「加载更早消息」按钮 + 滚到顶部自动触发 loadMoreHistory,
///   加载完成后按 (新 maxExtent - 旧 maxExtent) 补偿跳转,保持视口锚点不跳。
/// - 气泡内容渲染走 core ContentRendererRegistry(builtin_renderers 注册表)。
class ChatMessageList extends ConsumerStatefulWidget {
  final String convId;
  final String? agentId;
  final String currentUserId;
  final String baseUrl;
  final String token;

  const ChatMessageList({
    super.key,
    required this.convId,
    this.agentId,
    required this.currentUserId,
    required this.baseUrl,
    required this.token,
  });

  @override
  ConsumerState<ChatMessageList> createState() => _ChatMessageListState();
}

class _ChatMessageListState extends ConsumerState<ChatMessageList> {
  final ScrollController _scroll = ScrollController();

  /// 用户是否在底部(px >= maxScrollExtent - 50 容差)。
  bool _isAtBottom = true;

  /// loadMore 前的 (px, maxScrollExtent),加载完成后做锚点补偿。
  double? _loadMoreAnchorPx;
  double? _loadMoreAnchorMax;

  ({String convId, String? agentId}) get _key =>
      (convId: widget.convId, agentId: widget.agentId);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // 进会话滚到底:列表挂载(消息已就绪)后首帧布局完成再跳。
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    final pos = _scroll.position;
    _isAtBottom = pos.pixels >= pos.maxScrollExtent - 50;
    // 滚到顶部附近自动加载更早历史。
    // !_isAtBottom 守卫:内容不满一屏(maxScrollExtent≈0)时贴底即顶,
    // 避免进会话的贴底 jumpTo 误触发 loadMore。
    if (!_isAtBottom && pos.pixels <= 200 && _loadMoreAnchorPx == null) {
      _maybeLoadMore();
    }
  }

  void _jumpToBottom() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _jumpToBottomAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToBottom());
  }

  void _maybeLoadMore() {
    final state = ref.read(chatProvider(_key));
    if (state.isLoadingMore || !state.hasMore || state.displayMessages.isEmpty) {
      return;
    }
    if (!_scroll.hasClients) return;
    // 记录锚点:loadMore 在列表头插入内容,完成后按 extent 增量补偿。
    _loadMoreAnchorPx = _scroll.position.pixels;
    _loadMoreAnchorMax = _scroll.position.maxScrollExtent;
    ref.read(chatProvider(_key).notifier).loadMoreHistory();
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatProvider(_key));
    // displayMessages newest-first → 单列表 oldest-first 渲染取反。
    final items = chat.displayMessages.reversed.toList();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;

    ref.listen(chatProvider(_key), (prev, next) {
      // 流式 delta / 新消息:在底部才贴底跟随(postFrame 兜底等布局完成)。
      final prevFirst = prev?.displayMessages.isEmpty ?? true
          ? null
          : prev!.displayMessages.first;
      final nextFirst = next.displayMessages.isEmpty
          ? null
          : next.displayMessages.first;
      final newestChanged = prevFirst == null && nextFirst != null ||
          (prevFirst != null &&
              nextFirst != null &&
              !identical(prevFirst, nextFirst));
      if (newestChanged && _isAtBottom) {
        _jumpToBottomAfterFrame();
      }
      // loadMore 完成:补偿视口,保持阅读位置不跳。
      if (prev != null && prev.isLoadingMore && !next.isLoadingMore) {
        if (_loadMoreAnchorPx != null && _scroll.hasClients) {
          final anchorPx = _loadMoreAnchorPx!;
          final anchorMax = _loadMoreAnchorMax!;
          _loadMoreAnchorPx = null;
          _loadMoreAnchorMax = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scroll.hasClients) return;
            final grown =
                _scroll.position.maxScrollExtent - anchorMax;
            _scroll.jumpTo((anchorPx + grown)
                .clamp(0.0, _scroll.position.maxScrollExtent));
          });
        } else {
          _loadMoreAnchorPx = null;
          _loadMoreAnchorMax = null;
        }
      }
    });

    if (items.isEmpty) {
      return Center(
        child: Text(
          '暂无消息',
          style: TextStyle(
            fontSize: 13,
            color: scheme.onSurface.withValues(alpha: 0.4),
          ),
        ),
      );
    }

    return CustomScrollView(
      controller: _scroll,
      slivers: [
        if (chat.hasMore)
          SliverToBoxAdapter(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: chat.isLoadingMore
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        key: const ValueKey('load_more'),
                        onPressed: _maybeLoadMore,
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          textStyle: const TextStyle(fontSize: 12),
                        ),
                        child: const Text('加载更早消息'),
                      ),
              ),
            ),
          ),
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (_, i) => _MessageBubble(
            key: ValueKey('msg_${items[i].id}'),
            message: items[i],
            isMe: items[i].senderId == widget.currentUserId,
            baseUrl: widget.baseUrl,
            token: widget.token,
            isDark: isDark,
            conversationMessages: items,
          ),
        ),
        // 单聊打字气泡(trailing 插槽,对齐 app):typing(TYPING_START)或
        // agent 生成中(agentStatus 有值)时显示。多聊(agent_session)恒不显:
        // 运行状态由 AppBar「灵光涌动」+ StopBar + 聚合卡承载(同 app 口径)。
        if (_showTypingBubble(chat))
          const SliverToBoxAdapter(child: TypingBubble()),
      ],
    );
  }

  /// 打字气泡显隐判定(对齐 app chat_page._refreshExtraItems 口径)。
  bool _showTypingBubble(ChatState chat) {
    final conv = ref
        .read(conversationProvider)
        .where((c) => c.id == widget.convId)
        .firstOrNull;
    final isAgentSession =
        conv?.isAgentSession ?? (chat.convType == 'agent_session');
    if (isAgentSession) return false;
    final typing = ref.watch(typingProvider.select((m) => m[widget.convId] ?? false));
    final generating =
        ref.watch(agentStatusProvider.select((s) => s[widget.convId])) != null;
    return typing || generating;
  }
}

/// 桌面简化气泡:左 agent / 右 user,宽度约束 ~70%,
/// 内容渲染委托 core ContentRendererRegistry(注册表见 builtin_renderers.dart)。
class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;
  final String baseUrl;
  final String token;
  final bool isDark;
  final List<ChatMessage> conversationMessages;

  const _MessageBubble({
    super.key,
    required this.message,
    required this.isMe,
    required this.baseUrl,
    required this.token,
    required this.isDark,
    required this.conversationMessages,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final msgType = MsgTypeX.fromString(message.content['msg_type'] as String?);

    // 子 agent 审批卡不在扁平流渲染(与 app 壳同口径)。
    if (message.isChildApprovalCard) return const SizedBox.shrink();

    // 撤回 / 压缩分割线:居中灰字占位。
    if (message.isRecalled || msgType == MsgType.compactDivider) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            message.isRecalled ? '消息已撤回' : '上下文已压缩',
            style: TextStyle(
              fontSize: 11,
              color: scheme.onSurface.withValues(alpha: 0.35),
            ),
          ),
        ),
      );
    }

    // tui_user 视作用户消息(app 壳同口径)。
    final effectiveIsMe = isMe || msgType == MsgType.tuiUser;

    return LayoutBuilder(
      builder: (context, constraints) {
        final rc = MessageRenderContext(
          isMe: effectiveIsMe,
          baseUrl: baseUrl,
          token: token,
          isDark: isDark,
          convId: message.conversationId,
          messageId: message.id,
          rootMessageId: message.id,
          conversationMessages: conversationMessages,
          isStreaming: message.isStreaming,
          // 图片消息点击 → 桌面全屏预览(core ImageContentRenderer 的
          // openGallery 回调机制,原图 URL 用 GalleryImage 拼)。
          openGallery: (fileId) {
            final img = GalleryImage.fromInternal(fileId, baseUrl, token);
            showImageViewer(context, url: img.url, headers: img.headers);
          },
        );
        final content =
            ContentRendererRegistry.render(msgType, message.content, context, rc);
        final wrapped = ContentRendererRegistry.shouldWrapInBubble(msgType)
            ? _BubbleShell(isMe: effectiveIsMe, child: content)
            : content;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 12),
          child: Row(
            mainAxisAlignment:
                effectiveIsMe ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Flexible(
                child: ConstrainedBox(
                  // 气泡最大占可用宽 95%(右侧留 5% 边距,对齐用户要求)。
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.95,
                  ),
                  child: wrapped,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 气泡外壳:user 蓝底 597BFF(对齐 app BubbleWithTail/TuiUserRenderer,
/// 深浅色同值)/ agent surfaceContainerHighest 底(与白卡片区分,浅色
/// EDEDED/深色 26272D 两模式均有对比),8px 圆角(桌面紧凑风,无三角)。
class _BubbleShell extends StatelessWidget {
  final bool isMe;
  final Widget child;

  const _BubbleShell({required this.isMe, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: isMe ? const Color(0xFF597BFF) : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}
