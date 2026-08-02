import 'package:flutter/material.dart';

import '../../models/slash_command.dart';
import '../../theme/app_colors.dart';
import 'slash_handle.dart' show AttachSide;

export 'slash_handle.dart' show AttachSide;

/// 命令面板 — 按 source 分组(命令/技能) + 搜索 + 列表。
///
/// 位置:紧邻感应线一侧(贴右→卡片在右;贴左→卡片在左),贴近顶部。
/// 点击命令直接调 onSelected(传整个 SlashCommand 对象),由 chat_page 决定后续行为
/// (填入输入栏当标签 + 聚焦等用户输入 args)。
class SlashCommandSheet extends StatefulWidget {
  final List<SlashCommand> commands;
  final AttachSide side;
  final void Function(SlashCommand cmd) onSelected;
  final VoidCallback onClose;

  const SlashCommandSheet({
    super.key,
    required this.commands,
    required this.side,
    required this.onSelected,
    required this.onClose,
  });

  @override
  State<SlashCommandSheet> createState() => _SlashCommandSheetState();
}

class _SlashCommandSheetState extends State<SlashCommandSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<SlashCommand> get _commandsGroup =>
      _filtered.where((c) => c.source == 'command').toList();

  List<SlashCommand> get _skillsGroup =>
      _filtered.where((c) => c.source == 'skill').toList();

  // source 既非 command 也非 skill 的项(老服务器降级 / 数据异常),
  // 在分组模式下作为兜底 bucket 渲染,避免搜索过滤后丢失。
  List<SlashCommand> get _otherGroup => _filtered
      .where((c) => c.source != 'command' && c.source != 'skill')
      .toList();

  // 原始 commands 中是否存在任何 source 分组信息。
  // false = 老服务器(或老 plugin)未返回 source 字段,所有项 source='',
  // 走扁平渲染避免用户看到空白面板(两组过滤后都空)。
  bool get _hasGroupInfo =>
      widget.commands.any((c) => c.source == 'command' || c.source == 'skill');

  List<SlashCommand> get _filtered {
    if (_query.isEmpty) return widget.commands;
    return widget.commands.where((c) {
      return c.name.toLowerCase().contains(_query) ||
          c.description.toLowerCase().contains(_query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final cardWidth = screenWidth * 0.6;
    final isRight = widget.side == AttachSide.right;

    return Stack(
      children: [
        GestureDetector(
          key: const ValueKey('slash-backdrop'),
          behavior: HitTestBehavior.translucent,
          onTap: widget.onClose,
          child: Container(color: Colors.transparent),
        ),
        Positioned(
          top: 64,
          right: isRight ? 14 : null,
          left: isRight ? null : 14,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: cardWidth,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: _buildSearchList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchList() {
    // 搜索框(两种渲染模式共用)
    final searchBox = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(4),
      ),
      child: TextField(
        controller: _searchCtrl,
        style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
          hintText: '搜索命令…',
          hintStyle: TextStyle(color: Color(0xFF999999), fontSize: 12),
        ),
      ),
    );

    // 老服务器降级:无 source 分组信息 → 扁平渲染所有过滤后项,不显示分组 header。
    if (!_hasGroupInfo) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          searchBox,
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 410),
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: _filtered.map(_buildCmdItem).toList(),
            ),
          ),
        ],
      );
    }

    // 新服务器:按 source 分组(命令在上 / 技能在下),
    // 其他无 source 项兜底渲染避免搜索过滤后丢失(实战极少,但防御)。
    final cmds = _commandsGroup;
    final skills = _skillsGroup;
    final others = _otherGroup;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        searchBox,
        // 列表(限高 + 可滚动)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 410),
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              if (cmds.isNotEmpty) ...[
                _buildSectionHeader('命令'),
                ...cmds.map(_buildCmdItem),
              ],
              if (skills.isNotEmpty) ...[
                _buildSectionHeader('技能'),
                ...skills.map(_buildCmdItem),
              ],
              if (others.isNotEmpty) ...[
                _buildSectionHeader('其他'),
                ...others.map(_buildCmdItem),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 2),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: Color(0xFF999999),
        ),
      ),
    );
  }

  Widget _buildCmdItem(SlashCommand cmd) {
    return InkWell(
      onTap: () => widget.onSelected(cmd),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '/${cmd.name}',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.accentGreen,
              ),
            ),
            if (cmd.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 1, 0, 8),
                child: Text(
                  cmd.description,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF888888)),
                ),
              ),
            const Divider(
              height: 1,
              thickness: 0.5,
              color: Color(0xFFF5F5F5),
            ),
          ],
        ),
      ),
    );
  }
}
