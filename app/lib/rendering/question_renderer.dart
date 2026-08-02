import 'package:flutter/material.dart';

/// question 工具渲染 body。
/// 由 ToolCallRenderer 在 name == "question" 时调用。
/// 暖色卡片 + 首题 header + 点击弹底部抽屉查看全部选项。
class QuestionBody extends StatelessWidget {
  final Map<String, dynamic> input;
  final String convId;
  const QuestionBody({super.key, required this.input, this.convId = ''});

  @override
  Widget build(BuildContext context) {
    final questions = input['questions'] as List<dynamic>? ?? [];
    if (questions.isEmpty) return const SizedBox.shrink();
    final q = questions[0] as Map<String, dynamic>?;
    if (q == null) return const SizedBox.shrink();
    final header = (q['header'] as String?) ?? '';
    final questionText = (q['question'] as String?) ?? '';
    final options = q['options'] as List<dynamic>? ?? [];
    final count = questions.length;

    return GestureDetector(
      onTap: () => _showSheet(context, questions.map((e) => Map<String, dynamic>.from(e as Map)).toList()),
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF7E6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFB388FF), width: 1.5),
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
            if (header.isNotEmpty || questionText.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                header.isNotEmpty ? header : questionText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: Color(0xFFB388FF)),
              ),
            ],
            if (options.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF0EB),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${String.fromCharCode(65)}. ${(options[0] as Map<String, dynamic>?)?['label'] ?? ''}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF7C4DFF)),
                ),
              ),
              if (options.length > 1)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '+${options.length - 1} 个选项',
                    style: const TextStyle(fontSize: 10, color: Color(0xFF999999)),
                  ),
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

  void _showSheet(BuildContext context, List<Map<String, dynamic>> questions) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => _QuestionOptionsSheet(
        questions: questions,
        convId: convId,
      ),
    );
  }
}

/// 只读底部抽屉：Tab 切换 + radio/checkbox 展示 + 导航按钮。
/// 问题通过终端的 tool_call 发出，APP 仅展示，不提交。
class _QuestionOptionsSheet extends StatefulWidget {
  final List<Map<String, dynamic>> questions;
  final String convId;
  const _QuestionOptionsSheet({
    required this.questions,
    this.convId = '',
  });

  @override
  State<_QuestionOptionsSheet> createState() => _QuestionOptionsSheetState();
}

class _QuestionOptionsSheetState extends State<_QuestionOptionsSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: widget.questions.length, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final multi = widget.questions.length > 1;
    final idx = _tab.index.clamp(0, widget.questions.length - 1);
    final last = widget.questions.length - 1;
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
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFDDDDDD),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
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
                        answered: false,
                      ),
                    ),
                ],
              ),
            const Divider(height: 1, color: Color(0xFFEEEEEE)),
            SizedBox(
              height: tabViewHeight,
              child: TabBarView(
                controller: _tab,
                children: [
                  for (var i = 0; i < widget.questions.length; i++)
                    _ReadOnlyQuestionPane(
                      question: widget.questions[i],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('拒绝',
                        style: TextStyle(color: Color(0xFFFA5151))),
                  ),
                  const Spacer(),
                  if (idx > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: TextButton(
                        onPressed: () => _tab.animateTo(idx - 1),
                        child: const Text('← 上一题',
                            style: TextStyle(color: Color(0xFF597BFF))),
                      ),
                    ),
                  TextButton(
                    onPressed: () {
                      if (idx < last) {
                        _tab.animateTo(idx + 1);
                      } else {
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('请在终端中回答'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      }
                    },
                    style: TextButton.styleFrom(
                      backgroundColor: const Color(0xFF597BFF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                    ),
                    child: Text(
                      idx == last ? '通过终端回答 →' : '下一题 →',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 只读问题面板：显示 question + 所有选项（radio/checkbox 样式）。
class _ReadOnlyQuestionPane extends StatelessWidget {
  final Map<String, dynamic> question;
  const _ReadOnlyQuestionPane({required this.question});

  @override
  Widget build(BuildContext context) {
    final questionText = (question['question'] as String?) ?? '';
    final header = (question['header'] as String?) ?? '';
    final multiple = question['multiple'] as bool? ?? false;
    final options = question['options'] as List<dynamic>? ?? [];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  header.isNotEmpty ? header : questionText,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF333333),
                  ),
                ),
                if (questionText.isNotEmpty && questionText != header) ...[
                  const SizedBox(height: 6),
                  Text(
                    questionText,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF666666),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                for (final opt in options)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: () {
                      final item = opt as Map<String, dynamic>;
                      final label = item['label'] as String? ?? '';
                      final desc = item['description'] as String? ?? '';
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: const Color(0xFFE0E0E0)),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 20,
                              height: 20,
                              margin: const EdgeInsets.only(top: 1),
                              decoration: BoxDecoration(
                                shape: multiple
                                    ? BoxShape.rectangle
                                    : BoxShape.circle,
                                borderRadius: multiple
                                    ? BorderRadius.circular(4)
                                    : null,
                                border: Border.all(
                                    color: const Color(0xFFCCCCCC), width: 2),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    label,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: Color(0xFF333333),
                                    ),
                                  ),
                                  if (desc.isNotEmpty)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(top: 2),
                                      child: Text(
                                        desc,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF888888),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tab 标签 + 右上角状态圆点。
class _TabWithDot extends StatelessWidget {
  final String label;
  final bool answered;
  const _TabWithDot({required this.label, required this.answered});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
          if (answered)
            Positioned(
              top: -4,
              right: -8,
              child: Container(
                width: 8,
                height: 8,
                decoration: const BoxDecoration(
                  color: Color(0xFF4CAF50),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
