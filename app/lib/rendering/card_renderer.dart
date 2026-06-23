import 'package:flutter/material.dart';

import '../models/approval.dart';
import '../widgets/card_button.dart';
import '../widgets/card_state_badge.dart';
import '../widgets/countdown_timer.dart';
import 'message_content_renderer.dart';

/// 卡片渲染器。渲染审批卡片（命令/工具/文件）+ 按钮 + 状态。
///
/// 不参与文字选择（selectable=false），由 MessageBubble 外层包 BubbleWithTail。
class CardContentRenderer implements MessageContentRenderer {
  const CardContentRenderer();

  /// 全局决策回调。ChatPage 启动时注入（Phase F Task 21）。
  /// 调用签名：(approvalId, actionId, reason?) → 错误文案（null 表示成功）
  static Future<String?> Function(String, String, String?)? onDecide;

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => false; // 卡片自带白底外壳，MessageBubble 仍给三角

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'] as Map<String, dynamic>?;
    if (data == null) return const Text('[卡片数据缺失]');
    final card = ApprovalCard.fromJson(data);
    return _CardView(card: card);
  }
}

class _CardView extends StatefulWidget {
  final ApprovalCard card;
  const _CardView({required this.card});

  @override
  State<_CardView> createState() => _CardViewState();
}

class _CardViewState extends State<_CardView> {
  ApprovalState? _optimisticState;
  String? _optimisticAction;
  bool _disabled = false;

  @override
  Widget build(BuildContext context) {
    final state = _optimisticState ?? widget.card.state;
    final isTerminal = state == ApprovalState.approved ||
        state == ApprovalState.denied ||
        state == ApprovalState.expired;

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
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
                    color: m.warn
                        ? const Color(0xFFFA8C16)
                        : const Color(0xFF888888),
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
                child: CountdownTimer(expiresAt: widget.card.expiresAt),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildTypeSpecific() {
    switch (widget.card.cardType) {
      case CardType.command:
        return [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.card.preview,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 6),
        ];
      case CardType.tool:
        return [
          Text(
            '🛠 ${widget.card.toolName}',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              widget.card.preview,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          const SizedBox(height: 6),
        ];
      case CardType.file:
        final f = widget.card.file;
        return [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
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
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF888888),
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
      default:
        return const [];
    }
  }

  String _fileMeta(ApprovalFile? f) {
    if (f == null) return '';
    final kb = (f.size / 1024).toStringAsFixed(1);
    return '$kb KB';
  }

  CardButtonState _buttonState(String actionId, ApprovalState state) {
    if (state == ApprovalState.pending) return CardButtonState.active;
    final decided = widget.card.decidedAction ?? _optimisticAction;
    if (decided == actionId) return CardButtonState.selected;
    return CardButtonState.disabled;
  }

  String _buttonLabel(ApprovalAction a, ApprovalState state) {
    final decided = widget.card.decidedAction ?? _optimisticAction;
    if (state == ApprovalState.approved && decided == a.id) {
      if (a.id == 'allow_once' || a.id == 'allow_always') return '已批准';
    }
    if (state == ApprovalState.denied && decided == a.id) {
      return '已拒绝';
    }
    return a.label;
  }

  Future<void> _onTap(String actionId) async {
    setState(() => _disabled = true);

    setState(() {
      _optimisticAction = actionId;
      _optimisticState =
          actionId == 'deny' ? ApprovalState.denied : ApprovalState.approved;
    });

    final err = await CardContentRenderer.onDecide?.call(
      widget.card.approvalId,
      actionId,
      null,
    );
    if (err != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
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
