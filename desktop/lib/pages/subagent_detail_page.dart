// desktop/lib/pages/subagent_detail_page.dart
import 'dart:async';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/auth_provider.dart'
    show apiProvider, authProvider;
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/utils/gallery_image.dart';

import '../shell/card_container.dart';
import '../theme/desktop_theme.dart';
import '../widgets/image_viewer.dart' show showImageViewer;

/// 子 Agent 详情页(桌面卡片版,移植自 app 壳 subagent_detail_page):
/// 展示某条 task 卡片下挂的全部子 agent 事件流。
///
/// 入口:core 渲染层 task 卡片点击 push
///   `/chat/subagent/:taskCardId?convId=:convId&title=...`
/// (tool_card_renderer 硬编码该 path,desktop 路由必须匹配)。
///
/// 数据层与 app 版一致(均在 wanling_core,无壳特有依赖):
///   - 初始:HTTP `api.getSubagentMessages(convId, taskCardId)` 拉 root 子树
///   - 增量 CREATE:WS MESSAGE_CREATE 且 dispatch payload 的
///     `root_msg_id == taskCardId` 实时追加
///   - 增量 UPDATE:WS MESSAGE_UPDATE(task 卡片状态变更)按 message_id
///     替换对应条目 content
///
/// 渲染与 app 版同构:事件流复用 core ContentRendererRegistry(工具卡/
/// markdown/text 等各自 renderer),气泡为桌面简化壳(无三角,app 壳的
/// BubbleWithTail 不在 core,desktop 不依赖 app 包)。isDark 用真主题亮度
/// (desktop 优势,app 版硬编码 false)。无文件下载(fileDownloadSnapshots/
/// onFileTap 留 null,core renderer 对 null 有点击降级);图片点击接
/// showImageViewer 全屏预览。
class SubagentDetailPage extends ConsumerStatefulWidget {
  /// task 卡片的消息 id,作为 root_msg_id 查询子树。
  final String taskCardId;

  /// task 卡片所在会话 id。
  final String convId;

  /// task 卡片的 description(= 任务名称),显示在顶栏。
  /// 空串退化为默认标题「子 Agent」。
  final String title;

  const SubagentDetailPage({
    super.key,
    required this.taskCardId,
    required this.convId,
    this.title = '',
  });

  @override
  ConsumerState<SubagentDetailPage> createState() =>
      _SubagentDetailPageState();
}

class _SubagentDetailPageState extends ConsumerState<SubagentDetailPage> {
  List<ChatMessage> _messages = [];
  bool _loading = true;
  String? _error;
  StreamSubscription<WSMessage>? _wsSub;
  StreamSubscription<WSMessage>? _wsUpdateSub;

  /// 列表滚动控制器:跳底按钮用。
  final ScrollController _scroll = ScrollController();

  /// 用户是否在底部(px >= maxScrollExtent - 50 容差,对齐 app 版)。
  bool _isAtBottom = true;

  @override
  void initState() {
    super.initState();
    _loadMessages();
    _listenWS();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _wsUpdateSub?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final msgs = await ref
          .read(apiProvider)
          .getSubagentMessages(widget.convId, widget.taskCardId);
      if (!mounted) return;
      setState(() {
        // server ListByRoot 返 ASC(最老在前),UI 顶部为最早事件。
        // 与 WS 已到达消息按 id 合并(而非整体覆盖),避免 await 窗口内
        // 到达的 WS MESSAGE_CREATE 被静默丢弃(对齐 app 版 wide-review I-2)。
        final existing = {for (final m in msgs) m.id};
        _messages = [
          ...msgs,
          ..._messages.where((m) => !existing.contains(m.id)),
        ];
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：${e.response?.statusMessage ?? e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  /// WS 增量订阅(对齐 app 版):
  /// - MESSAGE_CREATE:dispatch payload 顶层 `root_msg_id` 过滤本子树追加
  /// - MESSAGE_UPDATE:task 卡片状态变更(running→completed/error 等),
  ///   按 `message_id` 只替换 content(payload 缺 sender_type/created_at
  ///   等必填字段,不能整条 fromJson)
  void _listenWS() {
    final ws = ref.read(wsProvider);
    _wsSub = ws.messages.where((m) => m.t == 'MESSAGE_CREATE').listen((m) {
      final d = m.d as Map<String, dynamic>?;
      if (d == null) return;
      if (d['conversation_id'] != widget.convId) return;
      if (d['root_msg_id'] != widget.taskCardId) return;
      final msg = ChatMessage.fromJson(d);
      // 去重:WS 重连补发可能与初始 HTTP 拉取重叠
      if (_messages.any((existing) => existing.id == msg.id)) return;
      if (!mounted) return;
      setState(() => _messages = [..._messages, msg]);
    });

    _wsUpdateSub = ws.messageUpdates
        .where((m) => m.t == 'MESSAGE_UPDATE')
        .listen((m) {
      final d = m.d as Map<String, dynamic>?;
      if (d == null) return;
      final msgId = d['message_id'] as String?;
      if (msgId == null) return;
      final idx = _messages.indexWhere((existing) => existing.id == msgId);
      if (idx < 0) return; // 不在本 root 子树,忽略
      final newContent = d['content'] as Map<String, dynamic>?;
      if (newContent == null) return;
      if (!mounted) return;
      setState(() {
        final newList = List<ChatMessage>.of(_messages);
        newList[idx] = newList[idx].copyWith(content: newContent);
        _messages = newList;
      });
    });
  }

  /// 返回:正常从聊天 push 进来用 pop 回聊天;无路由栈可 pop
  /// (如深链直开)时兜底回消息页。
  void _back() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/messages');
    }
  }

  @override
  Widget build(BuildContext context) {
    return CardContainer(
      color: DesktopTheme.chatCardColor(Theme.of(context).brightness),
      child: Column(
        children: [
          // 顶栏:返回 + 标题 + 刷新(对齐 ChatAppBar 48px 高度风格)。
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color:
                      Theme.of(context).dividerTheme.color ?? const Color(0xFFE4E4E4),
                ),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('subagent_back'),
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回',
                  onPressed: _back,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title.isNotEmpty ? widget.title : '子 Agent',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const ValueKey('subagent_refresh'),
                  icon: const Icon(Icons.refresh),
                  tooltip: '刷新',
                  onPressed: _loadMessages,
                ),
              ],
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(
        key: const ValueKey('subagent_error_view'),
        message: _error!,
        onRetry: _loadMessages,
      );
    }
    final events = _messages;
    if (events.isEmpty) {
      return Center(
        child: Text(
          '暂无子 Agent 内容',
          style: TextStyle(
            fontSize: 14,
            color: scheme.onSurface.withValues(alpha: 0.4),
          ),
        ),
      );
    }
    // 事件流复用 core 渲染注册表(对齐 app 版):每种 msg_type 各自 renderer,
    // isMe=false(子 agent 消息对当前用户都是接收方视角)。
    // baseUrl/token 从 settingsProvider/authProvider 直取(desktop 版无
    // _downloadService 壳);isDark 用真主题亮度(desktop 优势)。
    // rootMessageId=taskCardId:嵌套 task 卡跳子详情时按根查子树
    // (aggregate_card_renderer 的 elementRc 模式,此处根即 taskCardId)。
    // onFileTap/fileDownloadSnapshots 留 null:desktop 未接文件下载基建,
    // core renderer 对 null 有点击降级(无操作/未下载态)。
    final baseUrl = ref.watch(settingsProvider);
    final token = ref.watch(authProvider.select((s) => s.token ?? ''));
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n is ScrollMetricsNotification) return false;
            final metrics = n.metrics;
            final atBottom = !metrics.hasViewportDimension ||
                metrics.pixels >= metrics.maxScrollExtent - 50;
            if (atBottom != _isAtBottom) {
              setState(() => _isAtBottom = atBottom);
            }
            return false;
          },
          child: ListView.builder(
            key: const ValueKey('subagent_event_list'),
            controller: _scroll,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: events.length,
            itemBuilder: (ctx, i) {
              final msg = events[i];
              final msgType = MsgTypeX.fromString(
                msg.content['msg_type'] as String?,
              );
              // step_finish 过程态不渲染(对齐 app 版)。
              if (msgType == MsgType.stepFinish) {
                return const SizedBox.shrink();
              }
              final rc = MessageRenderContext(
                isMe: false,
                baseUrl: baseUrl,
                token: token,
                isDark: isDark,
                convId: widget.convId,
                messageId: msg.id,
                rootMessageId: widget.taskCardId,
                conversationMessages: _messages,
                // 图片点击 → 桌面全屏预览(对齐 chat_message_list 模式)。
                openGallery: (fileId) {
                  final img = GalleryImage.fromInternal(fileId, baseUrl, token);
                  showImageViewer(ctx, url: img.url, headers: img.headers);
                },
              );
              final content =
                  ContentRendererRegistry.render(msgType, msg.content, ctx, rc);
              final bubble =
                  ContentRendererRegistry.shouldWrapInBubble(msgType)
                      ? _Bubble(child: content)
                      : content;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: bubble,
              );
            },
          ),
        ),
        if (!_isAtBottom)
          Positioned(
            bottom: 16,
            right: 16,
            child: _JumpToBottomButton(onTap: _scrollToBottom),
          ),
      ],
    );
  }

  /// 平滑滚到底部(对齐 app 版)。
  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }
}

/// 桌面简化气泡壳(agent 侧,isMe 恒 false):surfaceContainerHighest 底 +
/// 8px 圆角,无三角(对齐 chat_message_list 的 _BubbleShell agent 分支;
/// app 壳的 BubbleWithTail 不在 core,desktop 不依赖 app 包)。
class _Bubble extends StatelessWidget {
  final Widget child;

  const _Bubble({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: child,
    );
  }
}

/// 跳底浮动按钮(桌面简版,app 壳 JumpToBottomButton 私有不可复用):
/// 右下角圆形 + 下箭头,颜色跟随主题(desktop 深色模式优势)。
class _JumpToBottomButton extends StatelessWidget {
  final VoidCallback onTap;

  const _JumpToBottomButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            Icons.keyboard_arrow_down,
            size: 24,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// 错误兜底视图:失败文案 + 重试按钮。
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: scheme.onSurface.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurface.withValues(alpha: 0.5),
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onRetry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 路由参数校验失败页(fail-fast,router builder 内使用):
/// taskCardId/convId 缺失或非 UUID 时渲染,不放行到 api 拼无效路径。
class SubagentParamErrorView extends StatelessWidget {
  /// 提示文案(区分缺参/格式错)。
  final String message;

  const SubagentParamErrorView({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return CardContainer(
      key: const ValueKey('subagent_param_error'),
      color: DesktopTheme.chatCardColor(Theme.of(context).brightness),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '参数错误',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () {
                if (context.canPop()) {
                  context.pop();
                } else {
                  context.go('/messages');
                }
              },
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
