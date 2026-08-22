import 'package:flutter/material.dart';

import 'package:wanling_core/models/agent_mode.dart';

/// 模式选择弹出框(清单驱动:plugin 上报的 AGENT_MODES 清单)。
/// mode id/label/style 全由插件上报定义,APP 不理解业务语义,
/// style 档位映射色点(default=品牌蓝/plan=橙/warn=红)。
class ModePickerDialog extends StatelessWidget {
  final List<AgentMode> modes;
  final String? currentMode;

  const ModePickerDialog({
    super.key,
    required this.modes,
    this.currentMode,
  });

  static Future<String?> show({
    required BuildContext context,
    required List<AgentMode> modes,
    String? currentMode,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => ModePickerDialog(modes: modes, currentMode: currentMode),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '选择模式',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.close,
                        size: 16,
                        color: scheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 12),
                children: [
                  for (final mode in modes)
                    _ModeRow(
                      mode: mode,
                      selected:
                          mode.id.toLowerCase() == currentMode?.toLowerCase(),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  final AgentMode mode;
  final bool selected;

  const _ModeRow({required this.mode, required this.selected});

  static Color _styleColor(String style) {
    switch (style.visualStyle) {
      case AgentModeVisualStyle.plan:
        return const Color(0xFFF4A742);
      case AgentModeVisualStyle.warn:
        return const Color(0xFFE5484D);
      case AgentModeVisualStyle.brand:
        return const Color(0xFF597BFF);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => Navigator.of(context).pop(mode.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: _styleColor(mode.style),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  mode.label.isEmpty ? mode.id : mode.label,
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
            if (selected)
              Icon(
                Icons.check,
                size: 18,
                color: scheme.onSurface.withValues(alpha: 0.7),
              ),
          ],
        ),
      ),
    );
  }
}
