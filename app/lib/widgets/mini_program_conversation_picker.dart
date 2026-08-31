// 小程序分享目标会话选择器:底部弹层列出会话,点击返回 convId。
// 取消/点遮罩返回 null(调用方 bridge 转 cancelled)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/conversation_provider.dart'
    show conversationProvider;

/// 弹出会话选择器。选中返回 convId;取消/点遮罩返回 null。
Future<String?> showMiniProgramConversationPicker({
  required BuildContext context,
  required WidgetRef ref,
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (_) => const Material(
      child: SafeArea(child: _PickerList()),
    ),
  );
}

class _PickerList extends ConsumerWidget {
  const _PickerList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final convs = ref.watch(conversationProvider);
    if (convs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: Text('暂无会话')),
      );
    }
    return ListView.builder(
      shrinkWrap: true,
      itemCount: convs.length,
      itemBuilder: (_, i) {
        final conv = convs[i];
        final name = conv.displayName;
        return ListTile(
          leading: CircleAvatar(
            child: Text(name.isNotEmpty ? name.characters.first : '?'),
          ),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => Navigator.pop(context, conv.id),
        );
      },
    );
  }
}
