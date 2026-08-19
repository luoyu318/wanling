import 'package:flutter/material.dart';

import 'package:wanling_core/models/participant.dart' show Participant;

/// 桌面 @ 提及面板:列出会话参与者,↑↓ 高亮 / Enter/点击选中。
/// 与 [SlashPanel] 同构(slash_panel.dart 共无共享依赖,各自独立实现)。
class MentionPanel extends StatefulWidget {
  final List<Participant> members;
  final int highlightedIndex;
  final ValueChanged<int> onHover;
  final ValueChanged<Participant> onSelected;

  const MentionPanel({
    super.key,
    required this.members,
    required this.highlightedIndex,
    required this.onHover,
    required this.onSelected,
  });

  @override
  State<MentionPanel> createState() => _MentionPanelState();
}

class _MentionPanelState extends State<MentionPanel> {
  final List<GlobalKey> _itemKeys = [];

  @override
  void didUpdateWidget(MentionPanel old) {
    super.didUpdateWidget(old);
    if (old.highlightedIndex != widget.highlightedIndex ||
        old.members != widget.members) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final idx = widget.highlightedIndex;
        if (idx < 0 || idx >= _itemKeys.length) return;
        final ctx = _itemKeys[idx].currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 80));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    _itemKeys.clear();
    for (var i = 0; i < widget.members.length; i++) {
      _itemKeys.add(GlobalKey());
    }
    return Material(
      key: const ValueKey('mention_panel'),
      elevation: 8,
      borderRadius: BorderRadius.circular(8),
      color: scheme.surface,
      surfaceTintColor: scheme.surface,
      child: Container(
        constraints: const BoxConstraints(maxHeight: 288, maxWidth: 400),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.all(4),
          itemCount: widget.members.length,
          itemBuilder: (context, i) {
            final p = widget.members[i];
            final highlighted = i == widget.highlightedIndex;
            return InkWell(
              key: highlighted ? _itemKeys[i] : null,
              onTap: () => widget.onSelected(p),
              onHover: (_) => widget.onHover(i),
              child: Container(
                key: ValueKey('mention_panel_item_${p.memberId}'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: highlighted
                      ? scheme.primary.withValues(alpha: 0.08)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    _MemberAvatar(name: p.displayName),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      p.isAgent ? 'Agent' : '',
                      style: TextStyle(
                        fontSize: 10,
                        color: scheme.onSurface.withValues(alpha: 0.35),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// 成员圆头:displayName 首字符 + 稳定色块(无头像 URL 时的桌面紧凑兜底)。
class _MemberAvatar extends StatelessWidget {
  final String name;
  const _MemberAvatar({required this.name});

  static const _palette = [
    Color(0xFF07C160),
    Color(0xFF5B8DEF),
    Color(0xFFE6A23C),
    Color(0xFFF56C6C),
    Color(0xFF9072DB),
  ];

  @override
  Widget build(BuildContext context) {
    final ch = name.isEmpty ? '?' : name.characters.first;
    final color = _palette[ch.codeUnitAt(0) % _palette.length];
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        ch,
        style: const TextStyle(
            fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600),
      ),
    );
  }
}
