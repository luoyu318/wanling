// 扫码配对「选已有 agent」三选弹窗:授权技能使用(发子密钥)/接管绑定(重置主密钥)/取消。
// 独立文件而非并入 PairSelectAgentPage:页面已有完整列表+FutureBuilder 逻辑,
// sheet 含备注输入与选项编排,独立函数形态让页面一行调用,侵入最小、可单测。
// UI 文案为定稿(见 .superpowers/sdd/task-6-brief.md),逐字使用。
import 'package:flutter/material.dart';
import 'package:wanling_core/models/pairing.dart';

/// 三选结果:action='authorize'(note 为备注)或 'bind'。
/// 返回 null = 用户取消/点了遮罩。
Future<(String action, String note)?> showPairAgentActionSheet(
  BuildContext context,
  PairAgentSummary agent,
) {
  return showModalBottomSheet<(String, String)>(
    context: context,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (_) => _PairAgentActionSheet(agent: agent),
  );
}

class _PairAgentActionSheet extends StatefulWidget {
  final PairAgentSummary agent;

  const _PairAgentActionSheet({required this.agent});

  @override
  State<_PairAgentActionSheet> createState() => _PairAgentActionSheetState();
}

class _PairAgentActionSheetState extends State<_PairAgentActionSheet> {
  final _noteController = TextEditingController();

  @override
  void dispose() {
    _noteController.dispose(); // 资源释放（审计 F1）
    super.dispose();
  }

  void _done(String action) {
    Navigator.of(context).pop((action, _noteController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '如何授权该 Agent？',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: Color(0xFF111111),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '「${widget.agent.name}」',
              style: const TextStyle(fontSize: 13, color: Color(0xFF999999)),
            ),
            const SizedBox(height: 12),
            // 备注仅授权模式使用,server 缺省落「技能授权」
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: '备注',
                hintText: '技能授权',
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            _OptionTile(
              title: '授权技能使用',
              subtitle: '发放子密钥，不影响现有绑定',
              onTap: () => _done('authorize'),
            ),
            _OptionTile(
              title: '接管绑定',
              subtitle: '重置主密钥，原绑定将失效',
              destructive: true,
              onTap: () => _done('bind'),
            ),
            _OptionTile(
              title: '取消',
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool destructive;
  final VoidCallback onTap;

  const _OptionTile({
    required this.title,
    this.subtitle,
    this.destructive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        destructive ? const Color(0xFFFA5151) : const Color(0xFF111111);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: color,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 12,
                  color: destructive
                      ? const Color(0xFFFA5151)
                      : const Color(0xFF999999),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
