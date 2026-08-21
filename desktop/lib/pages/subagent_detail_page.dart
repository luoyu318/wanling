// desktop/lib/pages/subagent_detail_page.dart
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;

import '../shell/card_container.dart';
import '../theme/desktop_theme.dart';

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
/// UI 桌面化差异:无 Scaffold(DesktopShell 装进聊天卡槽);子事件不复用
/// core 渲染注册表,简化为桌面风事件卡(类型标签/状态点/时间/等宽预览),
/// 保持信息完整。无文件下载/图片画廊(app 壳基建,桌面版 YAGNI)。
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

  /// 渲染用事件列表:过滤 step_finish 过程态(对齐 app 版)。
  List<ChatMessage> get _events => _messages
      .where(
        (m) =>
            MsgTypeX.fromString(m.content['msg_type'] as String?) !=
            MsgType.stepFinish,
      )
      .toList();

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
    final events = _events;
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
    return ListView.builder(
      key: const ValueKey('subagent_event_list'),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      itemCount: events.length,
      itemBuilder: (ctx, i) => _EventCard(msg: events[i]),
    );
  }
}

/// 子事件卡片(桌面简化风):状态点 + 类型标签 + 时间 + 等宽内容预览。
class _EventCard extends StatelessWidget {
  final ChatMessage msg;

  const _EventCard({required this.msg});

  /// 事件类型中文标签。
  static String _typeLabel(MsgType t) => switch (t) {
        MsgType.text => '文本',
        MsgType.markdown => '回复',
        MsgType.reasoning => '思考',
        MsgType.toolCall => '工具调用',
        MsgType.toolCard => '工具卡',
        MsgType.toolResult => '工具结果',
        MsgType.toolError => '工具错误',
        MsgType.image => '图片',
        MsgType.file => '文件',
        MsgType.fileDiff => '文件变更',
        MsgType.subagent => '子任务',
        MsgType.question => '提问',
        MsgType.questionCard => '选择题',
        MsgType.permissionCard => '权限审批',
        MsgType.card => '审批',
        MsgType.slashEcho => '命令',
        _ => '事件',
      };

  /// 状态中文标签(仅已知状态;工具卡 running/completed/error,
  /// 审批卡 pending/approved/denied/expired 等)。
  static String? _statusLabel(String? raw) => switch (raw) {
        'running' => '运行中',
        'completed' => '完成',
        'error' => '失败',
        'pending' => '待处理',
        'approved' => '已同意',
        'denied' => '已拒绝',
        'rejected' => '已拒绝',
        'answered' => '已回答',
        'expired' => '已过期',
        '' || null => null,
        _ => raw,
      };

  static Color _statusColor(String? raw) => switch (raw) {
        'running' || 'pending' => const Color(0xFF576B95),
        'completed' || 'approved' || 'answered' => const Color(0xFF07C160),
        'error' ||
        'denied' ||
        'rejected' ||
        'expired' =>
          const Color(0xFFFA5151),
        _ => const Color(0xFF999999),
      };

  /// 内容预览:优先常见正文/名称字段,兜底 JSON 截断(保持信息完整)。
  String _preview() {
    final data = msg.content['data'];
    if (data is Map<String, dynamic>) {
      for (final k in const [
        'text', 'name', 'title', 'description', 'preview', 'filename',
      ]) {
        final v = data[k];
        if (v is String && v.isNotEmpty) {
          return v.length > 200 ? '${v.substring(0, 200)}…' : v;
        }
      }
    }
    final raw = jsonEncode(msg.content['data'] ?? msg.content);
    return raw.length > 200 ? '${raw.substring(0, 200)}…' : raw;
  }

  String _hhmmss(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final msgType = MsgTypeX.fromString(msg.content['msg_type'] as String?);
    final data = msg.content['data'];
    final status = data is Map<String, dynamic>
        ? data['status'] as String?
        : null;
    final statusLabel = _statusLabel(status);
    final secondary = scheme.onSurface.withValues(alpha: 0.5);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态点:有无状态都渲染(对齐左列,内容区对齐)。
          Container(
            margin: const EdgeInsets.only(top: 5),
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _statusColor(status),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _typeLabel(msgType),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                    if (statusLabel != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: _statusColor(status),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      _hhmmss(msg.createdAt),
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: secondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _preview(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: scheme.onSurface.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
        ],
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
