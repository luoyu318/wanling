import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/auth_provider.dart' show authProvider;
import 'package:wanling_core/providers/draft_provider.dart' show draftProvider;

/// 会话列表摘要行的草稿感知渲染。
///
/// 该会话草稿非空时,摘要替换为「红色书写 icon + 草稿文本」(单行省略);
/// 无草稿渲染 [fallback](原最后一条消息预览)。
///
/// watch draftProvider 全文:列表页可见时草稿不可能变化(改草稿必然在
/// 会话页,此时列表在路由栈下不 build),逐字 watch 无重建成本。
class DraftAwarePreview extends ConsumerWidget {
  final String convId;
  final Widget fallback;

  const DraftAwarePreview({
    super.key,
    required this.convId,
    required this.fallback,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uid = ref.watch(authProvider.select((s) => s.user?.id));
    if (uid == null) return fallback;
    final draft =
        ref.watch(draftProvider((ownerId: uid, convId: convId)));
    if (draft.isEmpty) return fallback;
    return Row(
      children: [
        const Icon(
          Icons.drive_file_rename_outline,
          size: 15,
          color: Color(0xFFFA5151),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Text(
            draft,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xFF999999),
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}
