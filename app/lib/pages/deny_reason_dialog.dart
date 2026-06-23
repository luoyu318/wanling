import 'package:flutter/material.dart';

/// 拒绝理由对话框。返回用户输入的文本（可为空字符串），取消返回 '__cancel__'。
Future<String?> showDenyReasonDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => const _DenyReasonDialog(),
  );
}

class _DenyReasonDialog extends StatefulWidget {
  const _DenyReasonDialog();

  @override
  State<_DenyReasonDialog> createState() => _DenyReasonDialogState();
}

class _DenyReasonDialogState extends State<_DenyReasonDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('拒绝理由（可选）'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: '告诉 agent 为什么拒绝',
          border: OutlineInputBorder(),
        ),
        maxLines: 3,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop('__cancel__'),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('确认拒绝'),
        ),
      ],
    );
  }
}
