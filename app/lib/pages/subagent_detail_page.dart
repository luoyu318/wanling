import 'dart:async';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider, authProvider;
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/services/file_download_service.dart' show FileDownloadService;
import '../utils/chat/gallery_opener.dart' show openGallery;
import '../widgets/chat/file_download_controller.dart'
    show FileDownloadContext, FileDownloadController;
import '../widgets/chat/jump_to_bottom_button.dart';
import '../widgets/chat/message_bubble.dart' show BubbleWithTail;

/// 子 Agent 详情页：展示某条 task 卡片下挂的全部子 agent 事件流。
///
/// 入口：聊天页 task 卡片（_TaskCardShell）点击 →
///   `/chat/subagent/:taskCardId?convId=:convId`。
///
/// 数据来源：
///   - 初始：HTTP `api.getSubagentMessages(convId, taskCardId)` 拉 root 子树
///     （server ListByRoot：WHERE root_msg_id = $1）
///   - 增量 CREATE：监听 ws.messages 中 MESSAGE_CREATE 且 dispatch payload 的
///     `root_msg_id == taskCardId` 的事件，实时追加
///   - 增量 UPDATE：监听 ws.messageUpdates 中 MESSAGE_UPDATE（task 卡片状态变更
///     running→completed/error 等），按 message_id 替换对应条目 content
///
/// 路径参数选择 taskCardId（= task 卡片消息 id = root_msg_id）而非 sub_session_id：
/// API 唯一支持的查询维度是 root_msg_id，sub_session_id 在 server 不暴露查询入口。
class SubagentDetailPage extends ConsumerStatefulWidget {
  /// task 卡片的消息 id，作为 root_msg_id 查询子树。
  final String taskCardId;

  /// task 卡片所在会话 id。
  final String convId;

  /// task 卡片的 description(= 任务名称),显示在 AppBar。
  /// 空串退化为默认标题「子 Agent 详情」。
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
  bool _isAtBottom = true;
  StreamSubscription<WSMessage>? _wsSub;
  StreamSubscription<WSMessage>? _wsUpdateSub;
  late final ScrollController _scrollController;

  // I-H:子 agent 详情页的文件下载控制器。子 agent 频繁输出 image/file 消息,
  // 需要可点击下载/打开(否则降级无操作,与聊天页体验不一致)。
  // 仿 chat_page:initState 构造一次 + dispose 释放,依赖 FileDownloadContext 注入
  // context / setState / mounted / downloadService(对齐下载服务的 baseUrl + token)。
  late final FileDownloadController _fileController;
  late final FileDownloadService _downloadService;

  @override
  void initState() {
    super.initState();
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
    _scrollController = ScrollController();
    _loadMessages();
    _listenWS();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _wsUpdateSub?.cancel();
    _fileController.dispose();
    _scrollController.dispose();
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
        // server ListByRoot 返 ASC（最老在前），UI 顶部为最早事件，符合时间线直觉。
        // wide-review I-2:HTTP 返回后与 _messages 按 id 合并(而非整体覆盖),
        // 避免 await 窗口内到达的 WS MESSAGE_CREATE 被静默丢弃。
        final existing = {for (final m in _messages) m.id};
        final merged = [...msgs, ..._messages.where((m) => !existing.contains(m.id))];
        _messages = merged;
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

  /// 监听 WS MESSAGE_CREATE 事件，按 root_msg_id 过滤追加。
  ///
  /// dispatch payload (m.d) 的顶层带 `root_msg_id` 字段（server processor.go
  /// 在 dispatchData 里 marshal），不在 content 内。直接读 m.d 字段即可。
  ///
  /// 同时订阅 ws.messageUpdates 处理 MESSAGE_UPDATE(task 卡片状态变更)，
  /// 按 message_id 替换 _messages 内对应条目，否则详情页打开期间 task 卡片
  /// 永远停在 running 脉冲（I-G）。
  void _listenWS() {
    final ws = ref.read(wsProvider);
    _wsSub = ws.messages
        .where((m) => m.t == 'MESSAGE_CREATE')
        .listen((m) {
      final d = m.d as Map<String, dynamic>?;
      if (d == null) return;
      // 仅本会话 + 本 root 下的子事件才追加
      if (d['conversation_id'] != widget.convId) return;
      if (d['root_msg_id'] != widget.taskCardId) return;
      final msg = ChatMessage.fromJson(d);
      // 去重：WS 重连补发可能与初始 HTTP 拉取重叠
      if (_messages.any((existing) => existing.id == msg.id)) return;
      if (!mounted) return;
      setState(() => _messages = [..._messages, msg]);
    });

    // I-G:订阅 MESSAGE_UPDATE,按 message_id 替换 _messages 内对应条目 content。
    // task 卡片 running→completed/error 走 PATCH /api/messages/:id,
    // server 广播 MESSAGE_UPDATE 让主聊天列表 + 详情页同步终态。
    //
    // 字段名必须是 message_id(对齐 server dispatch.go BroadcastMessageUpdate 的 payload),
    // 不能读 d['id'](payload 不带 id,只有 message_id/conversation_id/content)。
    // 替换逻辑只覆盖 content(仿 chat_provider._listenUpdates),不能整条 fromJson
    // (payload 缺 sender_type/created_at 等必填字段会抛错)。
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        surfaceTintColor: Colors.transparent,
        shape: const Border(
          bottom: BorderSide(color: Color(0xFFD9D9D9), width: 0.5),
        ),
        centerTitle: true,
        title: Text(
          widget.title.isNotEmpty ? widget.title : '子 Agent 详情',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.normal,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF07C160)),
      );
    }
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _loadMessages);
    }
    if (_messages.isEmpty) {
      return const Center(
        child: Text(
          '暂无子 Agent 内容',
          style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
        ),
      );
    }
    // 子事件用各自 msg_type 的 renderer 渲染（reasoning / tool_card / text / ...）。
    // isMe=false：子 agent 发出的消息对当前用户而言都是接收方视角。
    //
    // I-H:rc 必须注入 convId + messageId,否则嵌套 task 卡片跳转拼出
    // `/chat/subagent/?convId=` 让 GoRouter 解析失败;image/file 消息也无法点击。
    // messageId 在 itemBuilder 内逐条注入(每条 msg 的 id 不同),rc 外壳用 const 共享不变字段。
    // wide-review I-1:rc 必须注入真实 baseUrl/token,否则 ImageContentRenderer 的
    // thumbUrl('', id) 返相对 URL 无 host,缩略图全裂。复用 _downloadService 已取的值。
    // wide-review M-2:fileDownloadSnapshots 在 build 顶层算一次复用,不在 itemBuilder 逐条重建。
    final snapshots = _fileController.buildSnapshots();
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
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: _messages.length,
            itemBuilder: (ctx, i) {
              final msg = _messages[i];
              final msgType = MsgTypeX.fromString(
                msg.content['msg_type'] as String?,
              );
              if (msgType == MsgType.stepFinish) return const SizedBox.shrink();
              final rc = MessageRenderContext(
                isMe: false,
                baseUrl: _downloadService.baseUrl,
                token: _downloadService.token,
                isDark: false,
                convId: widget.convId,
                messageId: msg.id,
                conversationMessages: _messages,
                openGallery: (fileId) => openGallery(
                  context: ctx,
                  ref: ref,
                  fileId: fileId,
                  messages: _messages,
                ),
                onFileTap: _fileController.onFileTap,
                fileDownloadSnapshots: snapshots,
              );
              final content = ContentRendererRegistry.render(msgType, msg.content, ctx, rc);
              final bubble = ContentRendererRegistry.shouldWrapInBubble(msgType)
                  ? BubbleWithTail(isMe: false, child: content)
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
            child: JumpToBottomButton(onTap: _scrollToBottom),
          ),
      ],
    );
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }
}

/// 错误兜底视图：失败文案 + 重试按钮。
class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 48, color: Color(0xFFB0B0B0)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF999999), fontSize: 13),
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
