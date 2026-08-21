import 'package:flutter/material.dart';

import 'message_content_renderer.dart';

/// 文件 diff 渲染器：固定高度 header（文件名 + +/- 统计），点击弹出底部抽屉查看完整 diff。
class FileDiffRenderer implements MessageContentRenderer {
  const FileDiffRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(BuildContext context, Map<String, dynamic> content, MessageRenderContext rc) {
    final data = content['data'] as Map<String, dynamic>? ?? {};
    final file = (data['file'] as String?) ?? '';
    final additions = (data['additions'] as num?)?.toInt() ?? 0;
    final deletions = (data['deletions'] as num?)?.toInt() ?? 0;
    final diff = (data['diff'] as String?) ?? '';
    final isDark = rc.isDark;

    return GestureDetector(
      onTap: diff.isNotEmpty ? () => _showDetail(context, file, additions, deletions, diff, isDark: rc.isDark) : null,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          // 深色:卡底 FAFAFA → 26272D(对齐既定深色卡底色板)
          color: isDark ? const Color(0xFF26272D) : const Color(0xFFFAFAFA),
          borderRadius: BorderRadius.circular(6),
          border: const Border(left: BorderSide(color: Color(0xFFBBBBBB), width: 3)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              // 深色灰阶反转:近黑标题 #111 → #EEEEEE
              Text(file, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF111111))),
              const Spacer(),
              Text('+$additions', style: const TextStyle(fontSize: 11, color: Color(0xFF07C160))),
              const SizedBox(width: 4),
              Text('−$deletions', style: const TextStyle(fontSize: 11, color: Color(0xFFFA5151))),
              if (diff.isNotEmpty) ...[
                const SizedBox(width: 4),
                // 深色灰阶反转:#999 → #777777
                Text('▸', style: TextStyle(fontSize: 11, color: isDark ? const Color(0xFF777777) : const Color(0xFF999999))),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context, String file, int additions, int deletions, String diff, {bool isDark = false}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      // 抽屉深色底对齐 showDetailSheet 体系(1E1F24),浅色白底不变。
      backgroundColor: isDark ? const Color(0xFF1E1F24) : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(top: 8, bottom: 4),
                // 深色把手:#DDD → #3A3B42
                decoration: BoxDecoration(color: isDark ? const Color(0xFF3A3B42) : const Color(0xFFDDDDDD), borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  const Text('📝 ', style: TextStyle(fontSize: 16)),
                  // 深色灰阶反转:#333 → #EEEEEE
                  Text(file, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333))),
                  const Spacer(),
                  Text('+$additions', style: const TextStyle(fontSize: 13, color: Color(0xFF07C160))),
                  const SizedBox(width: 4),
                  Text('−$deletions', style: const TextStyle(fontSize: 13, color: Color(0xFFFA5151))),
                ]),
              ),
              // 深色分割线:#EEE → #2E2F36
              Divider(height: 1, color: isDark ? const Color(0xFF2E2F36) : const Color(0xFFEEEEEE)),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: diff.split('\n').map((line) {
                      final isAdd = line.startsWith('+ ');
                      final isDel = line.startsWith('- ');
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 0.5),
                        child: Text(
                          line,
                          style: TextStyle(
                            fontFamily: 'monospace', fontSize: 12, height: 1.4,
                            // 语义色(新增绿/删除红)保留;普通行深色 #999 → #777777
                            color: isAdd ? const Color(0xFF07C160) : (isDel ? const Color(0xFFFA5151) : (isDark ? const Color(0xFF777777) : const Color(0xFF999999))),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
