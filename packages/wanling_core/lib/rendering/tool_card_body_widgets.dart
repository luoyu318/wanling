import 'package:flutter/material.dart';

import 'package:wanling_core/theme/app_colors.dart';

// ─── bash ─────────────────────────────────────────
class BashBody extends StatelessWidget {
  final Map<String, dynamic> input;

  /// 深色模式(桌面端):抽屉底/标题适配;浅色(app 壳)不变。
  /// 终端块 1E1E1E + 青 4FC3F7 双模式保持(本来就深色)。
  final bool isDark;
  const BashBody({super.key, required this.input, this.isDark = false});

  @override
  Widget build(BuildContext context) {
    final command = (input['command'] as String?) ?? '';
    final workdir = (input['workdir'] as String?) ?? '';
    return GestureDetector(
      onTap: () => _showDetail(context, command, workdir),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(4)),
            child: Text('\$ $command', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF4FC3F7))),
          ),
          if (workdir.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('📂 ${basename(workdir)}', style: const TextStyle(fontSize: 10, color: Color(0xFFAAAAAA)))),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context, String command, String workdir) {
    showDetailSheet(context,
      isDark: isDark,
      title: Text('Bash 命令', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(6)),
            child: SelectableText('\$ $command',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5, color: Color(0xFF4FC3F7))),
          ),
          if (workdir.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('📂 $workdir', style: const TextStyle(fontSize: 12, color: Color(0xFF999999))),
          ],
        ],
      ),
    );
  }
}

// ─── edit ─────────────────────────────────────────
class EditBody extends StatelessWidget {
  final Map<String, dynamic> input;

  /// 深色模式(桌面端):预览框底/抽屉适配;浅色(app 壳)不变。红绿语义色不动。
  final bool isDark;
  const EditBody({super.key, required this.input, this.isDark = false});

  @override
  Widget build(BuildContext context) {
    final oldStr = (input['oldString'] as String?) ?? '';
    final newStr = (input['newString'] as String?) ?? '';
    if (oldStr.isEmpty && newStr.isEmpty) return const SizedBox.shrink();
    final filePath = (input['filePath'] as String?) ?? '';
    return GestureDetector(
      onTap: () => _showDetail(context, oldStr, newStr, filePath),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (filePath.isNotEmpty)
            Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(basename(filePath), style: const TextStyle(fontSize: 11, color: Color(0xFF999999)))),
          // 改前框:旧内容单行预览(红字 - 前缀)
          if (oldStr.isNotEmpty)
            _editPreviewBox(
              lines: oldStr.split('\n').map((l) => '- $l').toList(),
              color: const Color(0xFFFA5151),
            ),
          if (newStr.isNotEmpty) ...[
            const SizedBox(height: 4),
            // 改后框:新内容单行预览(绿字 + 前缀)
            _editPreviewBox(
              lines: newStr.split('\n').map((l) => '+ $l').toList(),
              color: const Color(0xFF07C160),
            ),
          ],
        ],
      ),
    );
  }

  /// 编辑单行预览框:灰底容器,内容限一行(换行压平 + 超长 ellipsis),点击弹抽屉看全 diff。
  Widget _editPreviewBox({required List<String> lines, required Color color}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(6),
      // 深色:工具卡(2E2F36)内的二级嵌块回扣卡底色 26272D 区分层次
      decoration: BoxDecoration(color: isDark ? const Color(0xFF26272D) : const Color(0xFFF2F2F2), borderRadius: BorderRadius.circular(4)),
      child: Text(
        lines.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: color),
      ),
    );
  }

  void _showDetail(BuildContext context, String oldStr, String newStr, String filePath) {
    final allLines = <String>[];
    for (final l in oldStr.split('\n')) allLines.add('- $l');
    for (final l in newStr.split('\n')) allLines.add('+ $l');
    showDetailSheet(context,
      isDark: isDark,
      title: Text(filePath.isNotEmpty ? basename(filePath) : '编辑', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: allLines.map((l) {
          final isAdd = l.startsWith('+ ');
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: SelectableText(l, style: TextStyle(
              fontFamily: 'monospace', fontSize: 13, height: 1.4,
              color: isAdd ? const Color(0xFF07C160) : const Color(0xFFFA5151),
            )),
          );
        }).toList(),
      ),
    );
  }
}

// ─── read ─────────────────────────────────────────
class ReadBody extends StatelessWidget {
  final Map<String, dynamic> input;

  /// 深色模式(桌面端):块底/抽屉适配;浅色(app 壳)不变。蓝语义色不动。
  final bool isDark;
  const ReadBody({super.key, required this.input, this.isDark = false});

  @override
  Widget build(BuildContext context) {
    final filePath = (input['filePath'] as String?) ?? '';
    if (filePath.isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => _showDetail(context, filePath),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(6),
        // 深色:工具卡(2E2F36)内的二级嵌块回扣卡底色 26272D 区分层次
        decoration: BoxDecoration(color: isDark ? const Color(0xFF26272D) : const Color(0xFFF2F2F2), borderRadius: BorderRadius.circular(4)),
        child: Text(basename(filePath), style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF5B8BF7))),
      ),
    );
  }

  void _showDetail(BuildContext context, String filePath) {
    showDetailSheet(context,
      isDark: isDark,
      title: Text('读取文件', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [SelectableText(filePath, style: TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5, color: isDark ? const Color(0xFFC8C8C8) : const Color(0xFF555555)))],
      ),
    );
  }
}

// ─── grep ─────────────────────────────────────────
class GrepBody extends StatelessWidget {
  final Map<String, dynamic> input;

  /// 深色模式(桌面端):块底/抽屉适配;浅色(app 壳)不变。橙语义色不动。
  final bool isDark;
  const GrepBody({super.key, required this.input, this.isDark = false});

  @override
  Widget build(BuildContext context) {
    final pattern = (input['pattern'] as String?) ?? '';
    final path = (input['path'] as String?) ?? '';
    final include = (input['include'] as String?) ?? '';
    return GestureDetector(
      onTap: () => _showDetail(context, pattern, path, include),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(6),
        // 深色:工具卡(2E2F36)内的二级嵌块回扣卡底色 26272D 区分层次
        decoration: BoxDecoration(color: isDark ? const Color(0xFF26272D) : const Color(0xFFF2F2F2), borderRadius: BorderRadius.circular(4)),
        child: Text(
          [
            if (pattern.isNotEmpty) 'pattern: $pattern',
            if (path.isNotEmpty) 'scope: ${basename(path)}',
            if (include.isNotEmpty) 'include: $include',
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFA8C16)),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context, String pattern, String path, String include) {
    showDetailSheet(context,
      isDark: isDark,
      title: Text('Grep 搜索', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SelectableText('pattern: $pattern', style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5, color: Color(0xFFFA8C16))),
          if (path.isNotEmpty) const SizedBox(height: 6),
          if (path.isNotEmpty)
            SelectableText('scope: $path', style: TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5, color: isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666))),
          if (include.isNotEmpty) const SizedBox(height: 6),
          if (include.isNotEmpty)
            SelectableText('include: $include', style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5, color: Color(0xFF999999))),
        ],
      ),
    );
  }
}

// ─── glob ─────────────────────────────────────────
class GlobBody extends StatelessWidget {
  final Map<String, dynamic> input;

  /// 深色模式(桌面端):块底/抽屉适配;浅色(app 壳)不变。橙语义色不动。
  final bool isDark;
  const GlobBody({super.key, required this.input, this.isDark = false});

  @override
  Widget build(BuildContext context) {
    final pattern = (input['pattern'] as String?) ?? '';
    return GestureDetector(
      onTap: () => _showDetail(context, pattern),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(6),
        // 深色:工具卡(2E2F36)内的二级嵌块回扣卡底色 26272D 区分层次
        decoration: BoxDecoration(color: isDark ? const Color(0xFF26272D) : const Color(0xFFF2F2F2), borderRadius: BorderRadius.circular(4)),
        child: Text(pattern, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFFA8C16))),
      ),
    );
  }

  void _showDetail(BuildContext context, String pattern) {
    showDetailSheet(context,
      isDark: isDark,
      title: Text('Glob 匹配', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [SelectableText(pattern, style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5, color: Color(0xFFFA8C16)))],
      ),
    );
  }
}

// ─── todowrite ────────────────────────────────────
/// todowrite 任务清单:折叠组风格。
/// 标题行 = 图标 + 「已完成 x/y 项」+ 箭头;点击展开/收起任务列表。
/// 展开内容始终渲染(Align heightFactor 收起时视觉高度 0),与聚合卡折叠组交互一致。
class TodoBody extends StatefulWidget {
  final Map<String, dynamic> input;

  /// 深色模式(桌面端):标题/箭头/任务行灰阶适配;浅色(app 壳)不变。
  final bool isDark;
  const TodoBody({super.key, required this.input, this.isDark = false});

  @override
  State<TodoBody> createState() => _TodoBodyState();
}

class _TodoBodyState extends State<TodoBody> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final todos = widget.input['todos'] as List<dynamic>? ?? [];
    if (todos.isEmpty) return const SizedBox.shrink();
    final completed = todos.where((t) {
      final todo = t as Map<String, dynamic>?;
      return todo?['status'] == 'completed';
    }).length;
    // 深色灰阶反转(对齐 _TodoFoldRow):#555 → #C8C8C8 / #BBB → #777777
    final isDark = widget.isDark;
    final titleColor = isDark ? const Color(0xFFC8C8C8) : const Color(0xFF555555);
    final arrowColor = isDark ? const Color(0xFF777777) : const Color(0xFFBBBBBB);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            children: [
              const Icon(Icons.checklist_rounded, size: 16, color: Color(0xFF07C160)),
              const SizedBox(width: 6),
              Text(
                '已完成 $completed/${todos.length} 项',
                style: TextStyle(fontSize: 14, color: titleColor),
              ),
              const Spacer(),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
                color: arrowColor,
              ),
            ],
          ),
        ),
        // 展开内容始终渲染:Align(heightFactor) 收起时视觉高度 0(不占位)。
        ClipRect(
          child: Align(
            alignment: Alignment.topCenter,
            heightFactor: _expanded ? 1.0 : 0.0,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final t in todos)
                    _todoRowFull(t as Map<String, dynamic>?),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _todoRowFull(Map<String, dynamic>? todo) {
    if (todo == null) return const SizedBox.shrink();
    final status = (todo['status'] as String?) ?? 'pending';
    final content = (todo['content'] as String?) ?? '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _todoIcon(status, size: 14),
          Expanded(
            child: Text(content, style: TextStyle(fontSize: 13, height: 1.4,
              // 深色灰阶反转(对齐 _TodoFoldRow):#333 → #EEEEEE;#999/#AAA 双模式可读保持
              color: status == 'completed' ? const Color(0xFF999999) : (status == 'in_progress' ? (widget.isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333)) : const Color(0xFFAAAAAA)),
            )),
          ),
        ],
      ),
    );
  }

  /// 任务状态图标:completed=绿底白字 ✓,in_progress=橙色 ●,pending=灰色 ○
  Widget _todoIcon(String status, {required double size}) {
    if (status == 'completed') {
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Container(
          width: size + 3,
          height: size + 3,
          decoration: BoxDecoration(
            color: AppColors.accentGreen,
            borderRadius: BorderRadius.circular(3),
          ),
          alignment: Alignment.center,
          child: Text('✓',
              style: TextStyle(
                  fontSize: size - 2,
                  color: Colors.white,
                  height: 1)),
        ),
      );
    }
    final icon = status == 'in_progress' ? '●' : '○';
    // 深色灰阶反转(对齐 _TodoFoldRow):#CCC → #777777(弱化未选中态)
    final color = status == 'in_progress'
        ? const Color(0xFFFA8C16)
        : (widget.isDark ? const Color(0xFF777777) : const Color(0xFFCCCCCC));
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Text(icon, style: TextStyle(fontSize: size, color: color)),
    );
  }
}

// ─── write ────────────────────────────────────────
class WriteBody extends StatelessWidget {
  final Map<String, dynamic> input;

  /// 深色模式(桌面端):块底/抽屉适配;浅色(app 壳)不变。
  final bool isDark;
  const WriteBody({super.key, required this.input, this.isDark = false});

  @override
  Widget build(BuildContext context) {
    final filePath = (input['filePath'] as String?) ?? '';
    final content = (input['content'] as String?) ?? '';
    final preview = content.split('\n').join(' ');
    return GestureDetector(
      onTap: () => _showDetail(context, filePath, content),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (filePath.isNotEmpty)
            Text(basename(filePath), style: const TextStyle(fontSize: 11, color: Color(0xFF999999))),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(6),
            // 深色:工具卡(2E2F36)内的二级嵌块回扣卡底色 26272D 区分层次
            decoration: BoxDecoration(color: isDark ? const Color(0xFF26272D) : const Color(0xFFF2F2F2), borderRadius: BorderRadius.circular(4)),
            child: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis,
                // 深色灰阶反转:#666 → #AAAAAA
                style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: isDark ? const Color(0xFFAAAAAA) : const Color(0xFF666666))),
          ),
        ],
      ),
    );
  }

  void _showDetail(BuildContext context, String filePath, String content) {
    showDetailSheet(context,
      isDark: isDark,
      title: Text(filePath.isNotEmpty ? basename(filePath) : '写入文件', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            // 深色:抽屉(1E1F24)内的内容块用 26272D 区分层次;标题级字色 #333 → #EEEEEE
            decoration: BoxDecoration(color: isDark ? const Color(0xFF26272D) : const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(6)),
            child: SelectableText(content,
              style: TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.5, color: isDark ? const Color(0xFFEEEEEE) : const Color(0xFF333333))),
          ),
        ],
      ),
    );
  }
}

// ─── helpers ──────────────────────────────────────
String basename(String path) {
  final parts = path.split('/');
  return parts.isNotEmpty ? parts.last : path;
}

/// 共享 bottom sheet 骨架：拖拽手柄 + 标题行 + divider + 可滚动内容。
/// [isDark] 深色模式(桌面端):抽屉底 1E1F24 + 把手 3A3B42 + 分割线 2E2F36;
/// 浅色(app 壳)白底不变。sheet 内文字色由调用方按 isDark 分支传入。
Future<void> showDetailSheet(BuildContext context, {
  required Widget title,
  required Widget body,
  bool isDark = false,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: isDark ? const Color(0xFF1E1F24) : Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 36, height: 4, margin: const EdgeInsets.only(top: 8, bottom: 4),
              decoration: BoxDecoration(color: isDark ? const Color(0xFF3A3B42) : const Color(0xFFDDDDDD), borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: title,
            ),
            Divider(height: 1, color: isDark ? const Color(0xFF2E2F36) : const Color(0xFFEEEEEE)),
            Flexible(child: body),
          ],
        ),
      ),
    ),
  );
}
