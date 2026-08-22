import 'package:flutter/material.dart';
import '../utils/mono_font.dart';

import 'package:wanling_core/models/approval.dart';
import 'package:wanling_core/utils/snackbar.dart';
import 'package:wanling_core/widgets/card_button.dart';
import 'package:wanling_core/widgets/card_state_badge.dart';
import 'package:wanling_core/widgets/countdown_timer.dart';
import 'message_content_renderer.dart';

/// 卡片渲染器。渲染审批卡片（命令/工具/文件）+ 按钮 + 状态。
///
/// 不参与文字选择（selectable=false），由 MessageBubble 外层包 BubbleWithTail。
class CardContentRenderer implements MessageContentRenderer {
  const CardContentRenderer();

  /// 全局决策回调。ChatPage 启动时注入（Phase F Task 21）。
  /// 调用签名：(approvalId, actionId, reason?, answers?) → 错误文案（null 表示成功）
  /// answers 仅 question 卡 answer 动作携带（选中选项 id 列表）。
  static Future<String?> Function(String, String, String?, List<String>?)?
      onDecide;

  @override
  bool get selectable => false;

  // 卡片自带底色外壳(深浅双色适配),MessageBubble 仍给三角
  @override
  bool get wrapInBubble => false;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'] as Map<String, dynamic>?;
    if (data == null) return const Text('[卡片数据缺失]');
    final card = ApprovalCard.fromJson(data);
    return _CardView(card: card, isDark: rc.isDark);
  }
}

/// card_renderer 外层 Container 左边框色，按 ApprovalState 分流。
/// pending 用蓝（对齐 tool_call 工具属性），终态复用 approvalBadgeColor。
Color _cardBorderColor(ApprovalState state) {
  switch (state) {
    case ApprovalState.approved:
    case ApprovalState.denied:
    case ApprovalState.expired:
      return approvalBadgeColor(state);
    default:
      return const Color(0xFF5B8BF7);
  }
}

class _CardView extends StatefulWidget {
  final ApprovalCard card;

  /// 深色模式:外壳/嵌块底/文字灰阶适配(浅色路径不变)。
  final bool isDark;
  const _CardView({required this.card, this.isDark = false});

  @override
  State<_CardView> createState() => _CardViewState();
}

class _CardViewState extends State<_CardView> {
  ApprovalState? _optimisticState;
  String? _optimisticAction;
  bool _disabled = false;
  /// question 卡选中选项 id 集合（单选至多 1 项,多选任意）
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    final state = _optimisticState ?? widget.card.state;
    final isTerminal = state == ApprovalState.approved ||
        state == ApprovalState.denied ||
        state == ApprovalState.expired;
    final isDark = widget.isDark;

    // 卡片状态变化(pending→终态 PATCH 回写)高度变化时平滑过渡:
    // 顶部锚定向下展开,动画期间裁剪,后续消息随之下移平滑。
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.95),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          // 深色:白底外壳 → 26272D
          color: isDark ? const Color(0xFF26272D) : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border(
            left: BorderSide(color: _cardBorderColor(state), width: 3),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    widget.card.title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (isTerminal)
                  CardStateBadge(
                    text: approvalBadgeText(state),
                    color: approvalBadgeColor(state),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ..._buildTypeSpecific(),
            if (widget.card.meta.isNotEmpty)
              ...widget.card.meta.map(
                (m) => Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${m.icon} ${m.text}',
                    style: TextStyle(
                      fontSize: 12,
                      // FA8C16 橙色警示为语义色保留;次要灰深色 #888 → #AAAAAA
                      color: m.warn
                          ? const Color(0xFFFA8C16)
                          : (isDark ? const Color(0xFFAAAAAA) : const Color(0xFF888888)),
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: widget.card.actions.map((a) {
                final btnState = _buttonState(a.id, state);
                final label = _buttonLabel(a, state);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: CardButton(
                      label: label,
                      iconName: a.icon,
                      style: a.style,
                      state: btnState,
                      isDark: isDark,
                      onTap: _disabled || isTerminal ? null : () => _onTap(a.id),
                    ),
                  ),
                );
              }).toList(),
            ),
            if (state == ApprovalState.pending)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: CountdownTimer(expiresAt: widget.card.expiresAt, isDark: isDark),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildTypeSpecific() {
    switch (widget.card.cardType) {
      case CardType.command:
      case CardType.slashConfirm:
        // slash_confirm 复用 command 的代码块预览（preview 是提示文案）。
        return [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            // 深色:#F2F2F2 嵌块 → 26272D(回扣卡底区分层次)
            decoration: BoxDecoration(
              color: widget.isDark ? const Color(0xFF26272D) : const Color(0xFFF2F2F2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.card.preview,
              style: const TextStyle(fontFamily: 'monospace', fontFamilyFallback: kMonoFontFallback, fontSize: 12),
            ),
          ),
          const SizedBox(height: 6),
        ];
      case CardType.tool:
        return [
          Text(
            capitalize(widget.card.toolName),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            // 深色:#F2F2F2 嵌块 → 26272D(回扣卡底区分层次)
            decoration: BoxDecoration(
              color: widget.isDark ? const Color(0xFF26272D) : const Color(0xFFF2F2F2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.card.preview,
              style: const TextStyle(fontFamily: 'monospace', fontFamilyFallback: kMonoFontFallback, fontSize: 12),
            ),
          ),
          const SizedBox(height: 6),
        ];
      case CardType.file:
        final f = widget.card.file;
        return [
          Container(
            padding: const EdgeInsets.all(8),
            // 深色:#F2F2F2 嵌块 → 26272D(回扣卡底区分层次)
            decoration: BoxDecoration(
              color: widget.isDark ? const Color(0xFF26272D) : const Color(0xFFF2F2F2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                const Icon(Icons.insert_drive_file,
                    color: Color(0xFFFA8C16), size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        f?.name ?? '',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _fileMeta(f),
                        style: TextStyle(
                          fontSize: 11,
                          // 深色灰阶反转:#888 → #AAAAAA
                          color: widget.isDark ? const Color(0xFFAAAAAA) : const Color(0xFF888888),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ];
      case CardType.question:
        // question：选项列表嵌块。pending 可交互（radio/checkbox），
        // 终态回显 answers 摘要（id 映射 label 后 join('、')）。
        // 用 Material 而非 Container:ListTile 的 ink 水纹需绘制在 Material 上
        final state = _optimisticState ?? widget.card.state;
        final isTerminal = state == ApprovalState.approved ||
            state == ApprovalState.denied ||
            state == ApprovalState.expired;
        return [
          Material(
            // 深色:#F2F2F2 嵌块 → 26272D(回扣卡底区分层次)
            color: widget.isDark ? const Color(0xFF26272D) : const Color(0xFFF2F2F2),
            borderRadius: BorderRadius.circular(4),
            child: isTerminal ? _questionAnswersSummary() : _questionOptions(),
          ),
          const SizedBox(height: 6),
        ];
      default:
        return const [];
    }
  }

  /// question 选项列表：单选整组包 RadioGroup（tile 只带 value，对齐 desktop
  /// settings_page 写法，避开 RadioListTile.groupValue/onChanged 弃用），
  /// 多选直接 CheckboxListTile 列表。
  Widget _questionOptions() {
    if (!widget.card.multiSelect) {
      return RadioGroup<String>(
        groupValue: _selected.isNotEmpty ? _selected.first : null,
        // RadioGroup.onChanged 不可空:disabled 时由 handler 内部 no-op
        onChanged: (v) {
          if (_disabled || v == null) return;
          _toggle(v);
        },
        child: Column(
          children: widget.card.options.map((o) => _optionTile(o)).toList(),
        ),
      );
    }
    return Column(
      children: widget.card.options.map((o) => _optionTile(o)).toList(),
    );
  }

  /// question 选项 tile：单选 radio（点击即选）/ 多选 checkbox（toggle）。
  Widget _optionTile(ApprovalOption o) {
    final selected = _selected.contains(o.id);
    // 卡片 pending 蓝既作左边框语义色,此处复用作选中色
    const activeColor = Color(0xFF5B8BF7);
    final title = Text(
      o.label,
      style: const TextStyle(fontSize: 13),
    );
    if (widget.card.multiSelect) {
      return CheckboxListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 6),
        controlAffinity: ListTileControlAffinity.leading,
        activeColor: activeColor,
        value: selected,
        title: title,
        onChanged: _disabled ? null : (_) => _toggle(o.id),
      );
    }
    return RadioListTile<String>(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      controlAffinity: ListTileControlAffinity.leading,
      activeColor: activeColor,
      value: o.id,
      title: title,
    );
  }

  /// question 选项点击：单选替换旧选,多选 toggle。
  void _toggle(String optionId) {
    setState(() {
      if (widget.card.multiSelect) {
        if (!_selected.remove(optionId)) _selected.add(optionId);
      } else {
        _selected
          ..clear()
          ..add(optionId);
      }
    });
  }

  /// 提交答案：按 options 顺序输出选中 id（Set 无序,保证请求确定性）。
  List<String> get _answerIds => widget.card.options
      .where((o) => _selected.contains(o.id))
      .map((o) => o.id)
      .toList();

  /// question 终态 answers 摘要：answers 存选项 id,优先映射 label,未知 id 原样展示。
  Widget _questionAnswersSummary() {
    final labelById = {
      for (final o in widget.card.options) o.id: o.label,
    };
    final text =
        widget.card.answers.map((a) => labelById[a] ?? a).join('、');
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          // 深色灰阶反转:#888 → #AAAAAA
          color: widget.isDark ? const Color(0xFFAAAAAA) : const Color(0xFF888888),
        ),
      ),
    );
  }

  String _fileMeta(ApprovalFile? f) {
    if (f == null) return '';
    final kb = (f.size / 1024).toStringAsFixed(1);
    return '$kb KB';
  }

  CardButtonState _buttonState(String actionId, ApprovalState state) {
    if (state == ApprovalState.pending) {
      // question:未选任何选项时「提交答案」置灰（拒绝不受限）
      if (widget.card.cardType == CardType.question &&
          actionId == 'answer' &&
          _selected.isEmpty) {
        return CardButtonState.disabled;
      }
      return CardButtonState.active;
    }
    final decided = widget.card.decidedAction ?? _optimisticAction;
    if (decided == actionId) return CardButtonState.selected;
    return CardButtonState.disabled;
  }

  String _buttonLabel(ApprovalAction a, ApprovalState state) {
    final decided = widget.card.decidedAction ?? _optimisticAction;
    if (state == ApprovalState.approved && decided == a.id) {
      // exec_approval: allow_once/allow_always → 已批准
      if (a.id == 'allow_once' || a.id == 'allow_always') return '已批准';
      // slash_confirm: once/always → 已确认
      if (a.id == 'once' || a.id == 'always') return '已确认';
      // question: answer → 已回答
      if (a.id == 'answer') return '已回答';
    }
    if (state == ApprovalState.denied && decided == a.id) {
      // exec_approval: deny → 已拒绝；slash_confirm: cancel → 已取消
      if (a.id == 'deny') return '已拒绝';
      if (a.id == 'cancel') return '已取消';
      // question: reject → 已拒绝
      if (a.id == 'reject') return '已拒绝';
    }
    return a.label;
  }

  Future<void> _onTap(String actionId) async {
    setState(() => _disabled = true);

    // question:提交答案携带选中选项 id 列表
    List<String>? answers;
    if (widget.card.cardType == CardType.question && actionId == 'answer') {
      answers = _answerIds;
    }

    // 终态映射：deny/cancel/reject → denied；其余（allow_once/allow_always/once/always/answer）→ approved
    final isDeny =
        actionId == 'deny' || actionId == 'cancel' || actionId == 'reject';
    setState(() {
      _optimisticAction = actionId;
      _optimisticState = isDeny ? ApprovalState.denied : ApprovalState.approved;
    });

    final err = await CardContentRenderer.onDecide?.call(
      widget.card.approvalId,
      actionId,
      null,
      answers,
    );
    if (err != null) {
      if (mounted) {
        showAppSnackBar(context, err, type: SnackBarType.error);
      }
      setState(() {
        _optimisticState = null;
        _optimisticAction = null;
        _disabled = false;
      });
    }
    // 成功：等 MESSAGE_UPDATE 来同步（chatProvider 处理），无需本地额外操作
  }
}
