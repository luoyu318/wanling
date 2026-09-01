// 小程序分享目标会话选择器:底部弹层 4 列会话宫格,点击返回 convId。
// 取消/点遮罩返回 null(调用方 bridge 转 cancelled)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/conversation_provider.dart'
    show conversationProvider;
import 'avatar.dart';

/// 弹出会话选择器(宫格式)。选中返回 convId;取消/点遮罩返回 null。
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
      child: SafeArea(child: _PickerGrid()),
    ),
  );
}

class _PickerGrid extends ConsumerWidget {
  const _PickerGrid();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final convs = ref.watch(conversationProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('分享到',
                style:
                    TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
        if (convs.isEmpty)
          const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('暂无会话')))
        else
          Flexible(
            child: GridView.count(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              crossAxisCount: 4,
              childAspectRatio: 0.85,
              children: [
                for (final conv in convs)
                  _PickerItem(
                    key: ValueKey('pick-${conv.id}'),
                    convId: conv.id,
                    name: conv.displayName,
                    avatarUrl: conv.displayAvatarUrl,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PickerItem extends StatelessWidget {
  final String convId;
  final String name;
  final String? avatarUrl;

  const _PickerItem({
    super.key,
    required this.convId,
    required this.name,
    this.avatarUrl,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.pop(context, convId),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Avatar(name: name, url: avatarUrl, size: 44, radius: 12),
          const SizedBox(height: 4),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }
}
