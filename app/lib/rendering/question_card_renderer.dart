import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/msg_type.dart';
import '../providers/auth_provider.dart' show apiProvider;
import '../utils/snackbar.dart';
import 'message_content_renderer.dart';

/// 弹出选择题审批底部抽屉。
///
/// 公共入口：被 [QuestionCardRenderer]（独立选择题卡渲染）和
/// `_PendingApprovalChip`（task 卡片下挂的审批缩略条）共用。
/// sheet widget [_QuestionReplySheet] 保持私有。
void showQuestionReplySheet(
  BuildContext context, {
  required String convId,
  required String ocRequestId,
  required List<Map<String, dynamic>> questions,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (ctx) => _QuestionReplySheet(
      convId: convId,
      ocRequestId: ocRequestId,
      questions: questions,
    ),
  );
}

/// 选择题卡片渲染器。
///
/// 渲染 OpenCode 发起的单选/多选/自定义问题。
/// - pending：紫色卡片 + 题数 + 首题 header + 「点击回答」提示；点击弹底部抽屉
/// - answered/rejected：灰阶终态卡片 + 结果摘要 + 半透明，不可再操作
///
/// 抽屉结构：TabBar（单题时隐藏）+ 每题 radio/checkbox/custom + 拒绝/上一题/下一题/提交。
/// 已答题 tab 标绿色圆点。提交后发 question_reply，plugin PATCH 卡片切终态，
/// APP 收 MESSAGE_UPDATE 由 chatProvider 替换 content，本 renderer.build 读
/// status 自然切终态。
///
/// wrapInBubble=false（自带卡片外壳）；selectable=true（卡片内文字可选）。
/// 无超时：与 OpenCode TUI 行为一致。
class QuestionCardRenderer implements MessageContentRenderer {
  const QuestionCardRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'] as Map<String, dynamic>? ?? {};
    final status = data['status'] as String? ?? 'pending';
    final questions = (data['questions'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        <Map<String, dynamic>>[];
    final ocRequestId = data['oc_request_id'] as String? ?? '';
    final result = data['result'] as String?;

    final isTerminal = status == 'answered' || status == 'rejected' || status == 'expired';
    if (isTerminal) {
      return _TerminalQuestionCard(
        status: status,
        questionCount: questions.length,
        result: result,
      );
    }

    return _PendingQuestionCard(
      questions: questions,
      onTap: () => showQuestionReplySheet(
        context,
        convId: rc.convId,
        ocRequestId: ocRequestId,
        questions: questions,
      ),
    );
  }
}

/// pending 卡片：暖色背景 + 紫色边框 + 题数 + 首题 header + 「点击回答 →」。
class _PendingQuestionCard extends StatelessWidget {
  final List<Map<String, dynamic>> questions;
  final VoidCallback onTap;

  const _PendingQuestionCard({
    required this.questions,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final count = questions.length;
    final firstHeader =
        questions.isNotEmpty ? (questions.first['header'] as String? ?? '') : '';
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.95),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7E6),
          borderRadius: BorderRadius.circular(8),
          border: const Border(left: BorderSide(color: Color(0xFFB388FF), width: 3)),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  count > 1 ? '选择题 · $count 个问题' : '选择题',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF7C4DFF),
                  ),
                ),
              ],
            ),
            if (firstHeader.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                firstHeader,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFFB388FF)),
              ),
            ],
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C4DFF),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  '点击回答 →',
                  style: TextStyle(fontSize: 11, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 终态卡片：灰阶 + 结果摘要 + 半透明，不可操作。
class _TerminalQuestionCard extends StatelessWidget {
  final String status;
  final int questionCount;
  final String? result;

  const _TerminalQuestionCard({
    required this.status,
    required this.questionCount,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final answered = status == 'answered';
    final expired = status == 'expired';
    // 设计稿三态：answered=绿，rejected=红，expired=灰
    final accent = expired
        ? const Color(0xFF757575)
        : answered
            ? const Color(0xFF2E7D32)
            : const Color(0xFFC62828);
    final bgColor = expired
        ? const Color(0xFFF5F5F5)
        : answered
            ? const Color(0xFFE8F5E9)
            : const Color(0xFFFFEBEE);
    final resultText = expired
        ? '会话已结束'
        : answered
            ? (result != null && result!.isNotEmpty ? '已回答 · $result' : '已回答')
            : '已拒绝';
    return Opacity(
      opacity: 0.75,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.95),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: accent, width: 3)),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text(
                  questionCount > 1
                      ? '选择题 · $questionCount 个问题'
                      : '选择题',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              resultText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: accent),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自定义选项 sentinel。加入 [ _QuestionState.selected] 集合表示用户选了「自定义输入」。
const _customSentinel = '__custom__';

/// 单题作答状态：选中集合（label 或 _customSentinel）+ 自定义文本控制器。
///
/// - multiple=false：selected 至多 1 个，新选替换旧选
/// - multiple=true：selected 可任意多个
/// - custom=true：可把 _customSentinel 加入 selected，配合 customCtrl 文本作答
class _QuestionState {
  final bool multiple;
  final bool custom;
  final Set<String> selected = {};
  final TextEditingController customCtrl = TextEditingController();

  _QuestionState({required this.multiple, required this.custom});

  /// 是否已作答（至少 1 个有效答案）。
  /// 只选了 custom 且未填文本视为未答。
  bool get answered {
    if (selected.isEmpty) return false;
    if (selected.length == 1 &&
        selected.first == _customSentinel &&
        customCtrl.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  /// 转成协议数组：labels + 自定义文本（trim 后非空才加）。
  List<String> get answers {
    final out = <String>[];
    for (final s in selected) {
      if (s == _customSentinel) {
        final t = customCtrl.text.trim();
        if (t.isNotEmpty) out.add(t);
      } else {
        out.add(s);
      }
    }
    return out;
  }

  void toggleOption(String label) {
    if (multiple) {
      if (selected.contains(label)) {
        selected.remove(label);
      } else {
        selected.add(label);
      }
    } else {
      if (selected.contains(label)) {
        selected.clear();
      } else {
        selected
          ..clear()
          ..add(label);
      }
    }
  }

  void toggleCustom() {
    if (selected.contains(_customSentinel)) {
      selected.remove(_customSentinel);
    } else {
      if (!multiple) selected.clear();
      selected.add(_customSentinel);
    }
  }

  void dispose() => customCtrl.dispose();
}

/// 回复底部抽屉：TabBar + 每题选项区 + 底部按钮。
class _QuestionReplySheet extends ConsumerStatefulWidget {
  final String convId;
  final String ocRequestId;
  final List<Map<String, dynamic>> questions;

  const _QuestionReplySheet({
    required this.convId,
    required this.ocRequestId,
    required this.questions,
  });

  @override
  ConsumerState<_QuestionReplySheet> createState() =>
      _QuestionReplySheetState();
}

class _QuestionReplySheetState extends ConsumerState<_QuestionReplySheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late final List<_QuestionState> _states;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: widget.questions.length, vsync: this);
    _states = widget.questions.map((q) {
      final multiple = q['multiple'] as bool? ?? false;
      final custom = q['custom'] as bool? ?? true;
      return _QuestionState(multiple: multiple, custom: custom);
    }).toList();
    // 监听 tab 切换（含滑动）以刷新底部按钮（上一题/下一题/提交）。
    _tab.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (!_tab.indexIsChanging) setState(() {});
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    for (final s in _states) {
      s.dispose();
    }
    _tab.dispose();
    super.dispose();
  }

  bool get _allAnswered => _states.every((s) => s.answered);

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final multi = widget.questions.length > 1;
    final idx = _tab.index.clamp(0, widget.questions.length - 1);
    final last = widget.questions.length - 1;
    // TabBarView 无固有高度，固定给一块区域（屏幕可用高度的一部分），
    // 内部 SingleChildScrollView 处理溢出。键盘弹起时可用高度收缩。
    final tabViewHeight =
        (mq.size.height - mq.viewInsets.bottom) * 0.4 < 220
            ? 220.0
            : (mq.size.height - mq.viewInsets.bottom) * 0.4;
    return Padding(
      padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
            maxHeight: (mq.size.height - mq.viewInsets.bottom) * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 拖拽把手
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // 头部 + 进度
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Text('❓ ', style: TextStyle(fontSize: 16)),
                  Text(
                    multi
                        ? '选择题 · ${idx + 1} / ${widget.questions.length}'
                        : '选择题',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF333333),
                    ),
                  ),
                ],
              ),
            ),
            // TabBar（单题隐藏）
            if (multi)
              TabBar(
                controller: _tab,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: const Color(0xFF5B3FD6),
                unselectedLabelColor: const Color(0xFF999999),
                indicatorColor: const Color(0xFF7A5CFF),
                indicatorSize: TabBarIndicatorSize.label,
                dividerHeight: 0,
                tabs: [
                  for (var i = 0; i < widget.questions.length; i++)
                    Tab(
                      child: _TabWithDot(
                        label: (widget.questions[i]['header'] as String?) ??
                            '题${i + 1}',
                        answered: _states[i].answered,
                      ),
                    ),
                ],
              ),
            const Divider(height: 1, color: Color(0xFFEEEEEE)),
            // 每题内容区（固定高度，内部滚动）
            SizedBox(
              height: tabViewHeight,
              child: TabBarView(
                controller: _tab,
                children: [
                  for (var i = 0; i < widget.questions.length; i++)
                    _QuestionPane(
                      question: widget.questions[i],
                      state: _states[i],
                      onChanged: _sending ? null : () => setState(() {}),
                    ),
                ],
              ),
            ),
            // 底部按钮：[拒绝] ... [上一题?] [下一题|提交]
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _sending ? null : _onReject,
                    child: const Text('拒绝',
                        style: TextStyle(color: Color(0xFFFA5151))),
                  ),
                  const Spacer(),
                  if (idx > 0)
                    TextButton(
                      onPressed: _sending
                          ? null
                          : () => _tab.animateTo(idx - 1),
                      child: const Text('上一题'),
                    ),
                  if (idx > 0) const SizedBox(width: 8),
                  if (idx == last)
                    FilledButton(
                      onPressed: (_sending || !_allAnswered)
                          ? null
                          : _onSubmit,
                      child: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text('提交回答'),
                    )
                  else
                    FilledButton(
                      onPressed: _sending
                          ? null
                          : () => _tab.animateTo(idx + 1),
                      child: const Text('下一题'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 拒绝：立即发 rejected:true，关闭抽屉，等 MESSAGE_UPDATE 重渲染终态。
  Future<void> _onReject() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      final content = <String, dynamic>{
        'msg_type': MsgType.questionReply.value,
        // silent:true — 控制类消息，不计未读、不注入 prompt（plugin SyncEngine 过滤）。
        'silent': true,
        'data': <String, dynamic>{
          'oc_request_id': widget.ocRequestId,
          'rejected': true,
        },
      };
      await ref.read(apiProvider).sendMessage(widget.convId, content);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _sending = false);
        showAppSnackBar(context, '提交失败，请重试', type: SnackBarType.error);
      }
    }
  }

  /// 提交：所有题已答才发，answers 数组（每题一个内层 label 数组）。
  Future<void> _onSubmit() async {
    if (_sending || !_allAnswered) return;
    setState(() => _sending = true);
    try {
      final answers = _states.map((s) => s.answers).toList();
      final content = <String, dynamic>{
        'msg_type': MsgType.questionReply.value,
        'silent': true,
        'data': <String, dynamic>{
          'oc_request_id': widget.ocRequestId,
          'answers': answers,
          'rejected': false,
        },
      };
      await ref.read(apiProvider).sendMessage(widget.convId, content);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _sending = false);
        showAppSnackBar(context, '提交失败，请重试', type: SnackBarType.error);
      }
    }
  }
}

/// Tab 标签：header 文字（>12 字截断）+ 已答题绿色圆点。
/// 文字颜色由外层 TabBar 的 labelColor/unselectedLabelColor 控制（不在此覆盖）。
class _TabWithDot extends StatelessWidget {
  final String label;
  final bool answered;

  const _TabWithDot({required this.label, required this.answered});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        ),
        if (answered) ...[
          const SizedBox(width: 4),
          Container(
            width: 6,
            height: 6,
            decoration: const BoxDecoration(
              color: Color(0xFF07C160),
              shape: BoxShape.circle,
            ),
          ),
        ],
      ],
    );
  }
}

/// 单题内容区：题干 + 选项（radio/checkbox）+ 自定义输入（可选）。
class _QuestionPane extends StatelessWidget {
  final Map<String, dynamic> question;
  final _QuestionState state;
  final VoidCallback? onChanged;

  const _QuestionPane({
    required this.question,
    required this.state,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final title = question['question'] as String? ?? '';
    final custom = state.custom;
    final options = (question['options'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList() ??
        <Map<String, dynamic>>[];
    final customChosen = state.selected.contains(_customSentinel);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: Color(0xFF222222)),
          ),
          if (options.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...options.map((o) => _OptionTile(
                  label: o['label'] as String? ?? '',
                  description: o['description'] as String? ?? '',
                  selected: state.selected.contains(o['label']),
                  multiple: state.multiple,
                  onTap: onChanged == null
                      ? null
                      : () {
                          state.toggleOption(o['label'] as String);
                          onChanged!();
                        },
                )),
          ],
          if (custom) ...[
            const SizedBox(height: 8),
            _OptionTile(
              label: '自定义输入',
              description: '',
              selected: customChosen,
              multiple: state.multiple,
              onTap: onChanged == null
                  ? null
                  : () {
                      state.toggleCustom();
                      onChanged!();
                    },
            ),
            if (customChosen) ...[
              const SizedBox(height: 8),
              TextField(
                controller: state.customCtrl,
                enabled: onChanged != null,
                minLines: 1,
                maxLines: 3,
                onChanged: (_) => onChanged!(),
                decoration: const InputDecoration(
                  hintText: '请输入自定义答案',
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(6)),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// 单个选项 tile：radio（单选圆形）/ checkbox（多选方形）+ label + description。
class _OptionTile extends StatelessWidget {
  final String label;
  final String description;
  final bool selected;
  final bool multiple;
  final VoidCallback? onTap;

  const _OptionTile({
    required this.label,
    required this.description,
    required this.selected,
    required this.multiple,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 指示器：radio=圆形（紫边 + 内紫点），checkbox=方形（紫底 + 白勾）
            Container(
              width: 18,
              height: 18,
              margin: const EdgeInsets.only(top: 2),
              decoration: BoxDecoration(
                shape: multiple ? BoxShape.rectangle : BoxShape.circle,
                borderRadius:
                    multiple ? BorderRadius.circular(3) : null,
                border: Border.all(
                  color: selected
                      ? const Color(0xFF7A5CFF)
                      : const Color(0xFFBBBBBB),
                  width: 2,
                ),
                color: multiple && selected
                    ? const Color(0xFF7A5CFF)
                    : Colors.transparent,
              ),
              alignment: Alignment.center,
              child: selected
                  ? (multiple
                      ? const Icon(Icons.check, size: 12, color: Colors.white)
                      : Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFF7A5CFF),
                            shape: BoxShape.circle,
                          ),
                        ))
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF333333))),
                  if (description.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(description,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF999999))),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
