import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_highlight/themes/a11y-light.dart';
import 'package:highlight/highlight.dart' show highlight;

import '../models/message.dart';
import '../utils/code_highlight.dart' show languageFromPath, highlightNodesToSpans;
import 'message_content_renderer.dart';
import 'permission_card_renderer.dart' show showPermissionReplySheet;
import 'question_card_renderer.dart' show showQuestionReplySheet;
import 'tool_card_body_widgets.dart';
import 'truncatable_text_block.dart';

/// 工具名常量(消除魔法字符串)。这些是 tool_card.data.name 的可能取值,
/// 由 plugin streamer 上报(对齐 opencode 工具调用名)。
/// 集中定义避免拼写漂移,且 IDE 可补全。
class ToolName {
  ToolName._();
  static const bash = 'bash';
  static const edit = 'edit';
  static const read = 'read';
  static const grep = 'grep';
  static const glob = 'glob';
  static const todowrite = 'todowrite';
  static const write = 'write';
  static const task = 'task';
  static const question = 'question';
}

/// 解析 read 工具 output 的 XML 标签格式。
///
/// read 工具 output 形如:
///
/// ```text
/// <path>/abs/path/file.dart</path>
/// <type>file</type>
/// <content>
/// 1: 第一行
/// 2: 第二行
/// </content>
/// ```
///
/// 解析失败(无 `<content>` 标签 / 格式不符)返回 null,调用方走原 monospace 兜底。
class _ParsedReadOutput {
  final String path;
  final String language;
  final String code;
  final int lineCount;

  const _ParsedReadOutput({
    required this.path,
    required this.language,
    required this.code,
    required this.lineCount,
  });
}

_ParsedReadOutput? _tryParseReadOutput(String raw) {
  final contentMatch =
      RegExp(r'<content>([\s\S]*?)</content>').firstMatch(raw);
  if (contentMatch == null) return null;
  final pathMatch = RegExp(r'<path>([^<]+)</path>').firstMatch(raw);
  final path = pathMatch?.group(1)?.trim() ?? '';

  // content 内每行格式 "N: xxx",去掉前缀还原纯代码。
  // 容忍 "N:" 无空格 / "N:  " 多空格,以及空行 "N: "。
  final rawLines = contentMatch.group(1)!.split('\n');
  final codeLines = rawLines.map((l) {
    final m = RegExp(r'^\s*\d+:\s?(.*)$').firstMatch(l);
    return m != null ? m.group(1)! : l;
  }).toList();
  // 去掉首尾空行(由 <content>\n + \n</content> 包裹产生)
  while (codeLines.isNotEmpty && codeLines.first.trim().isEmpty) {
    codeLines.removeAt(0);
  }
  while (codeLines.isNotEmpty && codeLines.last.trim().isEmpty) {
    codeLines.removeLast();
  }
  if (codeLines.isEmpty) return null;

  return _ParsedReadOutput(
    path: path,
    language: languageFromPath(path),
    code: codeLines.join('\n'),
    lineCount: codeLines.length,
  );
}

/// 工具卡片渲染器：将 tool_call + tool_result + tool_error + file_diff
/// 合并为单条消息的三态卡片。
///
/// - running: 蓝左边框 + input + 进行中指示
/// - completed: 绿左边框 + input + output + 可选 file_diff
/// - error: 红左边框 + input + 错误信息
class ToolCardRenderer implements MessageContentRenderer {
  const ToolCardRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(BuildContext context, Map<String, dynamic> content, MessageRenderContext rc) {
    final data = content['data'] as Map<String, dynamic>? ?? {};
    final status = data['status'] as String? ?? 'running';
    final name = data['name'] as String? ?? '';

    // task 工具特殊：3 状态机（starting/working/completed）+ 子 Agent 徽章 + 可点击跳转
    if (name == 'task') {
      switch (status) {
        case 'starting':
          return _wrapAnimated(_StartingTaskCard(data: data, rc: rc));
        case 'working':
          return _wrapAnimated(_WorkingTaskCard(data: data, rc: rc));
        case 'completed':
          return _wrapAnimated(_CompletedTaskCard(data: data, rc: rc));
        case 'error':
          // I-I:task error 状态保留「子 Agent」身份 + 跳转入口(对称 completed),
          // 不降级为普通工具错误卡片,让用户能点进去看失败上下文。
          return _wrapAnimated(_ErrorTaskCard(data: data, rc: rc));
        default:
          return _wrapAnimated(_WorkingTaskCard(data: data, rc: rc));
      }
    }

    // 普通 tool_card：原三态
    switch (status) {
      case 'completed':
        return _wrapAnimated(_CompletedToolCard(data: data));
      case 'error':
        return _wrapAnimated(_ErrorToolCard(data: data));
      default:
        return _wrapAnimated(_RunningToolCard(data: data));
    }
  }
}

/// 工具卡片高度变化(running→completed PATCH 回写 output 增高)时平滑过渡。
///
/// alignment topCenter:卡片顶部锚定、高度向下展开(不被撑起);动画期间默认
/// Clip.hardEdge 裁剪超出部分,内容随展开逐步露出,后续消息随之下移平滑。
/// 三态卡片是不同 widget 类型,必须包在最外层才能跨状态切换复用 element 触发动画。
Widget _wrapAnimated(Widget child) {
  return AnimatedSize(
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
    alignment: Alignment.topCenter,
    child: child,
  );
}

/// task 卡跳转子 Agent 详情页用的 root_msg_id。
///
/// 聚合卡内元素优先取 rc.rootMessageId（= 聚合卡真实消息 id），子会话消息的
/// root 指向该 id，用它才能拉到子树；非聚合场景 rootMessageId 为空时 fallback
/// 到 rc.messageId（= task 消息自身，即根）。
String _taskRootId(MessageRenderContext rc) =>
    rc.rootMessageId.isNotEmpty ? rc.rootMessageId : rc.messageId;

/// 从输入中提取当前操作的文件/目录上下文标签。
(String, String) _toolContext(Map<String, dynamic> input) {
  for (final field in ['filePath', 'path', 'workdir']) {
    final val = input[field] as String?;
    if (val != null && val.isNotEmpty) return (basename(val), field);
  }
  return ('', '');
}

/// 根据 tool name 构建 input body widget。
Widget _buildInputBody(String name, Map<String, dynamic> input) {
  return switch (name) {
    'bash' => BashBody(input: input),
    'edit' => EditBody(input: input),
    'read' => ReadBody(input: input),
    'grep' => GrepBody(input: input),
    'glob' => GlobBody(input: input),
    'todowrite' => TodoBody(input: input),
    'write' => WriteBody(input: input),
    _ => input.isNotEmpty
        ? TruncatableTextBlock(
            text: input.toString(),
            sheetTitle: Text(capitalize(name)),
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF666666)),
          )
        : const SizedBox.shrink(),
  };
}

/// 过长的 output 截断组件。
///
/// read 工具特化:解析 output 的 XML 标签(`<path>`/`<content>`),折叠态显示
/// 文件名 + 行数,展开抽屉用高亮代码视图(左侧行号列 + 右侧高亮)。
/// 其他工具走 TruncatableTextBlock 截断 + 点击弹抽屉看全文。
class _TruncatedOutput extends StatelessWidget {
  final String name;
  final String output;
  const _TruncatedOutput({required this.name, required this.output});

  @override
  Widget build(BuildContext context) {
    // read 工具:解析成功走文件预览样式
    final parsed = name == 'read' ? _tryParseReadOutput(output) : null;
    if (parsed != null) {
      final filename = parsed.path.isEmpty
          ? '文件'
          : parsed.path.split('/').last;
      return GestureDetector(
        onTap: () => _showReadDetail(context, parsed),
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
              color: const Color(0xFFF2F2F2),
              borderRadius: BorderRadius.circular(4)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.description_outlined,
                  size: 14, color: Color(0xFF5B8BF7)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '$filename · ${parsed.lineCount} 行',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF5B8BF7)),
                ),
              ),
              const SizedBox(width: 6),
              const Text('▸',
                  style: TextStyle(fontSize: 11, color: Color(0xFF999999))),
            ],
          ),
        ),
      );
    }

    // 其他工具:走通用截断组件
    return TruncatableTextBlock(
      text: output,
      sheetTitle: Text(capitalize(name), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
      textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF666666)),
    );
  }

  void _showReadDetail(BuildContext context, _ParsedReadOutput parsed) {
    final filename = parsed.path.isEmpty
        ? '文件内容'
        : parsed.path.split('/').last;
    showDetailSheet(
      context,
      title: Row(
        children: [
          const Icon(Icons.description_outlined,
              size: 18, color: Color(0xFF5B8BF7)),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  filename,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                if (parsed.path.isNotEmpty)
                  Text(
                    parsed.path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Color(0xFF999999),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
      body: _ReadCodeView(
        code: parsed.code,
        language: parsed.language,
        lineCount: parsed.lineCount,
      ),
    );
  }
}

/// 高亮代码视图:左侧行号列 + 右侧高亮代码列。
///
/// 设计要点:
/// - 整段代码一次 highlight.parse(保留跨行注释/字符串的高亮上下文,不能按行单独解析)
/// - 行号列与代码列共用相同字体度量(monospace 12px, height 1.5) → 每行视觉高度
///   一致,行号自然对齐
/// - 代码列 softWrap=false + 横向滚动 → 每行严格 1 行,长行不折行错位
/// - 抽屉背景固定白色(showDetailSheet hard-code),代码视图固定用 a11y-light 主题
class _ReadCodeView extends StatelessWidget {
  final String code;
  final String language;
  final int lineCount;

  const _ReadCodeView({
    required this.code,
    required this.language,
    required this.lineCount,
  });

  @override
  Widget build(BuildContext context) {
    const theme = a11yLightTheme;
    const fontStyle = TextStyle(
        fontFamily: 'monospace', fontSize: 12, height: 1.5);

    final result = highlight.parse(code, language: language);
    final spans = highlightNodesToSpans(result.nodes ?? const [], theme);

    return SingleChildScrollView(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 行号列
          Container(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            color: const Color(0xFFEEEEEE),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var i = 1; i <= lineCount; i++)
                  Text('$i', style: fontStyle.copyWith(color: const Color(0xFF999999))),
              ],
            ),
          ),
          // 代码列:横向滚动,长行不折行
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                color: theme['root']?.backgroundColor ?? Colors.white,
                child: RichText(
                  softWrap: false,
                  text: TextSpan(
                    style: fontStyle.copyWith(
                        color: theme['root']?.color ?? const Color(0xFF222222)),
                    children: spans,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// file_diff 紧凑行。
class _FileDiffRow extends StatelessWidget {
  final Map<String, dynamic> fileDiff;
  const _FileDiffRow({required this.fileDiff});

  @override
  Widget build(BuildContext context) {
    final file = fileDiff['file'] as String? ?? '';
    final additions = (fileDiff!['additions'] as num?)?.toInt() ?? 0;
    final deletions = (fileDiff!['deletions'] as num?)?.toInt() ?? 0;
    final diff = fileDiff!['diff'] as String? ?? '';
    return GestureDetector(
      onTap: diff.isNotEmpty ? () => _showDiffDetail(context, file, additions, deletions, diff) : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFF2F2F2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Text(file, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111111))),
            const Spacer(),
            Text('+$additions', style: const TextStyle(fontSize: 11, color: Color(0xFF07C160))),
            const SizedBox(width: 4),
            Text('−$deletions', style: const TextStyle(fontSize: 11, color: Color(0xFFFA5151))),
            if (diff.isNotEmpty) ...[
              const SizedBox(width: 4),
              const Text('▸', style: TextStyle(fontSize: 11, color: Color(0xFF999999))),
            ],
          ],
        ),
      ),
    );
  }

  void _showDiffDetail(BuildContext context, String file, int additions, int deletions, String diff) {
    showDetailSheet(context,
      title: Row(children: [
        Text(file, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF333333))),
        const Spacer(),
        Text('+$additions', style: const TextStyle(fontSize: 13, color: Color(0xFF07C160))),
        const SizedBox(width: 4),
        Text('−$deletions', style: const TextStyle(fontSize: 13, color: Color(0xFFFA5151))),
      ]),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          for (final line in diff.split('\n'))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 0.5),
              child: Text(line,
                style: TextStyle(
                  fontFamily: 'monospace', fontSize: 12, height: 1.4,
                  color: line.startsWith('+ ') ? const Color(0xFF07C160) : (line.startsWith('- ') ? const Color(0xFFFA5151) : const Color(0xFF999999)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── running card ──
class _RunningToolCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _RunningToolCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final name = (data['name'] as String?) ?? '';
    final input = data['input'] as Map<String, dynamic>? ?? {};
    final (contextLabel, contextField) = _toolContext(input);
    Map<String, dynamic> bodyInput = input;
    if (contextField.isNotEmpty) {
      bodyInput = Map<String, dynamic>.from(input)..remove(contextField);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: Color(0xFF5B8BF7), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Text(capitalize(name), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111111))),
            if (contextLabel.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(contextLabel, style: const TextStyle(fontSize: 11, color: Color(0xFF999999))),
            ],
            const Spacer(),
            const _PulseIndicator(),
          ]),
          if (bodyInput.isNotEmpty) ...[
            const SizedBox(height: 6),
            _buildInputBody(name, bodyInput),
          ],
        ],
      ),
    );
  }
}

/// 进行中脉冲指示器。
class _PulseIndicator extends StatefulWidget {
  /// 圆点和文案颜色，默认蓝色（普通 tool_card 进行中）。
  /// task 卡片用此传入对应状态色（starting 蓝 / working 橙）。
  final Color color;
  final String label;
  const _PulseIndicator({this.color = const Color(0xFF5B8BF7), this.label = '进行中'});

  @override
  State<_PulseIndicator> createState() => _PulseIndicatorState();
}

class _PulseIndicatorState extends State<_PulseIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _animation = Tween<double>(begin: 0.4, end: 1.0).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _animation,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6, height: 6,
            decoration: BoxDecoration(
              color: widget.color, shape: BoxShape.circle,
            ),
          ),
          if (widget.label.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(widget.label, style: const TextStyle(fontSize: 11, color: Color(0xFF999999))),
          ],
        ],
      ),
    );
  }
}

// ── completed card ──
class _CompletedToolCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _CompletedToolCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final name = (data['name'] as String?) ?? '';
    final input = data['input'] as Map<String, dynamic>? ?? {};
    final (contextLabel, contextField) = _toolContext(input);
    Map<String, dynamic> bodyInput = input;
    if (contextField.isNotEmpty) {
      bodyInput = Map<String, dynamic>.from(input)..remove(contextField);
    }
    final output = (data['output'] as String?) ?? '';
    final displayOutput = output.trim();
    final fileDiff = data['file_diff'] as Map<String, dynamic>?;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: Color(0xFF07C160), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Text(capitalize(name), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111111))),
            if (contextLabel.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(contextLabel, style: const TextStyle(fontSize: 11, color: Color(0xFF999999))),
            ],
            const Spacer(),
            const Text('完成', style: TextStyle(fontSize: 11, color: Color(0xFF07C160))),
          ]),
          if (bodyInput.isNotEmpty) ...[
            const SizedBox(height: 6),
            _buildInputBody(name, bodyInput),
          ],
          if (displayOutput.isNotEmpty && name != ToolName.todowrite) ...[
            const SizedBox(height: 4),
            if (displayOutput.length <= 80)
              Text(displayOutput, style: const TextStyle(fontSize: 12, color: Color(0xFF07C160)))
            else
              _TruncatedOutput(name: name, output: displayOutput),
          ],
          if (fileDiff != null) _FileDiffRow(fileDiff: fileDiff!),
        ],
      ),
    );
  }
}

// ── error card ──
class _ErrorToolCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _ErrorToolCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final name = (data['name'] as String?) ?? '';
    final input = data['input'] as Map<String, dynamic>? ?? {};
    final (contextLabel, contextField) = _toolContext(input);
    Map<String, dynamic> bodyInput = input;
    if (contextField.isNotEmpty) {
      bodyInput = Map<String, dynamic>.from(input)..remove(contextField);
    }
    final error = (data['error'] as String?) ?? '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F1),
        borderRadius: BorderRadius.circular(6),
        border: const Border(left: BorderSide(color: Color(0xFFFA5151), width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Text(capitalize(name), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111111))),
            if (contextLabel.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(contextLabel, style: const TextStyle(fontSize: 11, color: Color(0xFF999999))),
            ],
            const Spacer(),
            const Text('失败', style: TextStyle(fontSize: 11, color: Color(0xFFFA5151))),
          ]),
          if (bodyInput.isNotEmpty) ...[
            const SizedBox(height: 6),
            _buildInputBody(name, bodyInput),
          ],
          if (error.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(error, style: const TextStyle(fontSize: 12, color: Color(0xFFFA5151))),
          ],
        ],
      ),
    );
  }
}

// ── task 工具三态卡片（starting/working/completed）──
// 与普通 tool_card 区别：左侧带「子 Agent」徽章 + 状态文案 + 完成/进行中图标 +
// sub_session_id 非空时整体可点击跳转到子 Agent 详情页（Task 10 注册路由）。

class _StartingTaskCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final MessageRenderContext rc;
  const _StartingTaskCard({required this.data, required this.rc});

  @override
  Widget build(BuildContext context) {
    final input = (data['input'] as Map<String, dynamic>?) ?? {};
    return _TaskCardShell(
      agentType: (input['subagent_type'] as String?) ?? 'unknown',
      description: (input['description'] as String?) ?? '',
      statusText: '已启动',
      statusColor: const Color(0xFF5B8BF7),
      subSessionId: (data['sub_session_id'] as String?) ?? '',
      taskCardId: _taskRootId(rc),
      convId: rc.convId,
      conversationMessages: rc.conversationMessages,
      showPulse: true,
    );
  }
}

class _WorkingTaskCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final MessageRenderContext rc;
  const _WorkingTaskCard({required this.data, required this.rc});

  @override
  Widget build(BuildContext context) {
    final input = (data['input'] as Map<String, dynamic>?) ?? {};
    return _TaskCardShell(
      agentType: (input['subagent_type'] as String?) ?? 'unknown',
      description: (input['description'] as String?) ?? '',
      statusText: '正在执行',
      statusColor: const Color(0xFFFA8C16),
      subSessionId: (data['sub_session_id'] as String?) ?? '',
      taskCardId: _taskRootId(rc),
      convId: rc.convId,
      conversationMessages: rc.conversationMessages,
      showPulse: true,
    );
  }
}

class _CompletedTaskCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final MessageRenderContext rc;
  const _CompletedTaskCard({required this.data, required this.rc});

  @override
  Widget build(BuildContext context) {
    final input = (data['input'] as Map<String, dynamic>?) ?? {};
    final duration = (data['duration'] as num?)?.toDouble();
    final statusText = duration == null ? '完成' : '完成 · 用时 ${duration.toStringAsFixed(1)}s';
    return _TaskCardShell(
      agentType: (input['subagent_type'] as String?) ?? 'unknown',
      description: (input['description'] as String?) ?? '',
      statusText: statusText,
      statusColor: const Color(0xFF07C160),
      subSessionId: (data['sub_session_id'] as String?) ?? '',
      taskCardId: _taskRootId(rc),
      convId: rc.convId,
      conversationMessages: rc.conversationMessages,
      showPulse: false,
    );
  }
}

/// task 工具的 error 状态卡片(I-I)。
///
/// 与 _CompletedTaskCard 结构对称:保留「子 Agent」徽章 + 可点击跳转入口,
/// 让用户能点进详情页看失败上下文(对应 _TaskCardShell 的 GestureDetector 包装)。
/// 状态行用红色 + error 图标,左边界也用红色,与 completed 的绿色形成对比。
/// error 文案优先取 data['error'](plugin 上报),fallback 用 data['output']。
class _ErrorTaskCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final MessageRenderContext rc;
  const _ErrorTaskCard({required this.data, required this.rc});

  @override
  Widget build(BuildContext context) {
    final input = (data['input'] as Map<String, dynamic>?) ?? {};
    final errorText = (data['error'] as String?) ?? '';
    final outputText = (data['output'] as String?) ?? '';
    final detail = errorText.isNotEmpty ? errorText : outputText;
    final statusText = detail.isEmpty ? '失败' : '失败 · $detail';
    return _TaskCardShell(
      agentType: (input['subagent_type'] as String?) ?? 'unknown',
      description: (input['description'] as String?) ?? '',
      statusText: statusText,
      statusColor: const Color(0xFFFA5151),
      subSessionId: (data['sub_session_id'] as String?) ?? '',
      taskCardId: _taskRootId(rc),
      convId: rc.convId,
      conversationMessages: rc.conversationMessages,
      showPulse: false,
      statusIcon: Icons.cancel,
    );
  }
}

/// task 工具卡片外壳：左边框色 + 子 Agent 徽章 + 描述 + 状态行。
///
/// 当 [subSessionId] 非空时，整体包一层 GestureDetector，点击跳转到子 Agent
/// 详情页 `/chat/subagent/$taskCardId?convId=$convId`（路由在 Task 10 注册）。
///
/// 路径参数选择 [taskCardId]（= 本消息 id = root_msg_id）而非 [subSessionId]：
/// API `getSubagentMessages(convId, rootMsgId)` 按 root_msg_id 拉子树，
/// sub_session_id 只是 plugin 的子会话标识，server 不暴露按它查消息的接口。
/// [subSessionId] 保留作为「是否可点击」的开关（仅 sub-session 已建立才允许跳转）。
/// [convId] 来自 [MessageRenderContext.convId]，由 MessageBubble 从
/// message.conversationId 注入；[taskCardId] 来自 [MessageRenderContext] 的
/// rootMessageId（聚合卡内 = 聚合卡真实消息 id，非聚合场景 fallback messageId），
/// 见 [_taskRootId]。
class _TaskCardShell extends StatelessWidget {
  final String agentType;
  final String description;
  final String statusText;
  final Color statusColor;
  final String subSessionId;
  final String taskCardId;
  final String convId;
  final bool showPulse;
  // 状态行图标(completed=check_circle, error=cancel, starting/working 走 showPulse 分支)。
  // 默认 check_circle 保持 completed 调用方零改动。
  final IconData statusIcon;
  // 当前会话全部消息(用于反查 pending 子审批卡聚合渲染)。
  final List<ChatMessage> conversationMessages;

  const _TaskCardShell({
    required this.agentType,
    required this.description,
    required this.statusText,
    required this.statusColor,
    required this.subSessionId,
    required this.taskCardId,
    required this.convId,
    required this.showPulse,
    this.statusIcon = Icons.check_circle,
    this.conversationMessages = const [],
  });

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F7F7),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: statusColor, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (showPulse)
                _PulseIndicator(color: statusColor, label: '')
              else
                Icon(statusIcon, size: 14, color: statusColor),
              const SizedBox(width: 6),
              Text(
                agentType,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: statusColor),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF5856D6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('子 Agent', style: TextStyle(fontSize: 10, color: Colors.white)),
              ),
              const Spacer(),
              Text(statusText, style: TextStyle(fontSize: 11, color: statusColor)),
            ],
          ),
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(description, style: const TextStyle(fontSize: 12, color: Color(0xFF555555))),
            ),
        ],
      ),
    );

    // 聚合 pending 子审批卡(permission_card/question_card, parent 指向本 task)。
    // 子审批卡作为独立 ChatMessage 存在(由 chat_provider 放行进扁平列表),
    // 这里在 task 卡片渲染时从 conversationMessages 反查挂载到下方。
    final pendingApprovals = conversationMessages
        .where((m) => m.parentMsgId == taskCardId && m.isPendingChildApproval)
        .toList();

    Widget result = card;
    if (pendingApprovals.isNotEmpty && subSessionId.isNotEmpty) {
      result = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          card,
          ...pendingApprovals.map((m) => _PendingApprovalChip(
                message: m,
                convId: convId,
              )),
        ],
      );
    }

    if (subSessionId.isEmpty) return result;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push(
        '/chat/subagent/$taskCardId?convId=$convId&title=${Uri.encodeComponent(description)}',
      ),
      child: result,
    );
  }
}

class _PendingApprovalChip extends StatelessWidget {
  final ChatMessage message;
  final String convId;

  const _PendingApprovalChip({
    required this.message,
    required this.convId,
  });

  @override
  Widget build(BuildContext context) {
    final data = message.content['data'] as Map<String, dynamic>? ?? {};
    final msgType = message.content['msg_type'] as String? ?? '';
    final action = (data['action'] as String?) ?? '';
    const color = Color(0xFFFFA940);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _onChipTap(context, msgType: msgType, data: data),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7E6),
          borderRadius: BorderRadius.circular(6),
          border: const Border(left: BorderSide(color: color, width: 3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.bolt, size: 14, color: color),
            const SizedBox(width: 6),
            const Text('待审批', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            if (action.isNotEmpty) ...[
              const SizedBox(width: 6),
              Text('· $action', style: const TextStyle(fontSize: 11, color: Color(0xFF888888))),
            ],
          ],
        ),
      ),
    );
  }

  /// 按 msg_type 分发到对应审批抽屉。
  ///
  /// chip 的 message.content['data'] 字段结构与独立审批卡（PermissionCardRenderer /
  /// QuestionCardRenderer.build 内部解析的 data）完全一致——同一 server processor 上报，
  /// 因此字段提取逻辑对齐 renderer.build。
  void _onChipTap(BuildContext context, {required String msgType, required Map<String, dynamic> data}) {
    switch (msgType) {
      case 'permission_card':
        showPermissionReplySheet(
          context,
          convId: convId,
          ocRequestId: (data['oc_request_id'] as String?) ?? '',
          action: (data['action'] as String?) ?? '',
          resources: (data['resources'] as List?)?.cast<String>() ?? [],
          metadata: data['metadata'] as Map<String, dynamic>? ?? {},
          save: (data['save'] as List?)?.cast<String>() ?? [],
        );
        break;
      case 'question_card':
        showQuestionReplySheet(
          context,
          convId: convId,
          ocRequestId: (data['oc_request_id'] as String?) ?? '',
          questions: (data['questions'] as List?)
                  ?.map((e) => Map<String, dynamic>.from(e as Map))
                  .toList() ??
              <Map<String, dynamic>>[],
        );
        break;
      // 防御性:其他 msg_type 不响应(实际不会触发,因 chip 仅由 isPendingChildApproval 挂载,
      // 该判定只放行 permission_card / question_card 两种)。
    }
  }
}
