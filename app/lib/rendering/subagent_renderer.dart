import 'package:flutter/material.dart';

/// Subagent（task 工具）渲染 body。
/// 由 ToolCallRenderer 在 name == "task" 时调用。
class SubagentBody extends StatelessWidget {
  final Map<String, dynamic> input;
  const SubagentBody({super.key, required this.input});

  @override
  Widget build(BuildContext context) {
    final agentType = (input['subagent_type'] as String?) ?? 'unknown';
    final description = (input['description'] as String?) ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(agentType, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF5856D6))),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: const Color(0xFF5856D6), borderRadius: BorderRadius.circular(10)),
              child: const Text('子 Agent', style: TextStyle(fontSize: 10, color: Colors.white)),
            ),
          ],
        ),
        if (description.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(description, style: const TextStyle(fontSize: 12, color: Color(0xFF555555)))),
      ],
    );
  }
}
