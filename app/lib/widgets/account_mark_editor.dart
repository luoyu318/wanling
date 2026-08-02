import 'package:flutter/material.dart';
import '../models/account_mark.dart';
import '../theme/account_palette.dart';

/// 账号标记编辑器:颜色圆点单选 + emoji 文本框。
///
/// 纯展示组件,通过 onChanged 回调输出当前选择。
/// initial=null 表示无标记(无选中颜色 + 空 emoji)。
/// 输出 null 表示用户清空了所有选择(无颜色且无 emoji)。
class AccountMarkEditor extends StatefulWidget {
  final AccountMark? initial;
  final ValueChanged<AccountMark?> onChanged;

  const AccountMarkEditor({
    super.key,
    this.initial,
    required this.onChanged,
  });

  @override
  State<AccountMarkEditor> createState() => _AccountMarkEditorState();
}

class _AccountMarkEditorState extends State<AccountMarkEditor> {
  late int? _colorIndex;
  late TextEditingController _emojiCtrl;

  @override
  void initState() {
    super.initState();
    _colorIndex = widget.initial?.colorIndex;
    _emojiCtrl = TextEditingController(text: widget.initial?.emoji ?? '');
  }

  @override
  void dispose() {
    _emojiCtrl.dispose();
    super.dispose();
  }

  void _emit() {
    final emoji = _emojiCtrl.text.trim();
    if (_colorIndex == null && emoji.isEmpty) {
      widget.onChanged(null);
    } else {
      widget.onChanged(AccountMark(
        colorIndex: _colorIndex ?? 0,
        emoji: emoji.isEmpty ? null : emoji,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('颜色标记',
            style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            // 「无」选项
            GestureDetector(
              key: const ValueKey('palette_none'),
              onTap: () {
                setState(() => _colorIndex = null);
                _emit();
              },
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _colorIndex == null
                        ? primary
                        : const Color(0xFFCCCCCC),
                    width: _colorIndex == null ? 2.5 : 1,
                  ),
                ),
                child:
                    const Icon(Icons.close, size: 14, color: Color(0xFF999999)),
              ),
            ),
            // 8 色圆点
            for (int i = 0; i < AccountPalette.colors.length; i++)
              GestureDetector(
                key: ValueKey('palette_$i'),
                onTap: () {
                  setState(() => _colorIndex = i);
                  _emit();
                },
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AccountPalette.colors[i],
                    border: Border.all(
                      color:
                          _colorIndex == i ? Colors.white : Colors.transparent,
                      width: 2.5,
                    ),
                    boxShadow: _colorIndex == i
                        ? [
                            BoxShadow(
                              color: AccountPalette.colors[i]
                                  .withValues(alpha: 0.5),
                              blurRadius: 4,
                              spreadRadius: 1.5,
                            ),
                          ]
                        : null,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        const Text('Emoji(可选)',
            style: TextStyle(fontSize: 12, color: Color(0xFF999999))),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('mark_emoji_field'),
          controller: _emojiCtrl,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '如 🟢 / 🐱',
            isDense: true,
          ),
          onChanged: (_) => _emit(),
        ),
      ],
    );
  }
}
