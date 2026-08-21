// desktop/lib/widgets/settings_nav_pane.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/settings_nav_provider.dart';

/// 设置页左卡片导航:分区列表(外观/通用/账号/关于),点击发
/// [settingsScrollToProvider] 脉冲让右卡片滚动定位;高亮跟随
/// [settingsActiveSectionProvider](右侧滚动反推)。选中态与会话
/// 列表同语言:主色 10% tint + 名称 w600。
class SettingsNavPane extends ConsumerWidget {
  const SettingsNavPane({super.key});

  static const sections = [
    (Icons.palette_outlined, '外观'),
    (Icons.tune, '通用'),
    (Icons.account_circle_outlined, '账号'),
    (Icons.info_outline, '关于'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final active = ref.watch(settingsActiveSectionProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
          child: Text('设置',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              )),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            itemCount: sections.length,
            itemBuilder: (_, i) {
              final (icon, label) = sections[i];
              final selected = i == active;
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Container(
                  decoration: BoxDecoration(
                    color:
                        selected ? scheme.primary.withValues(alpha: 0.10) : null,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: InkWell(
                    key: ValueKey('settings_nav_$label'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      ref.read(settingsActiveSectionProvider.notifier).state = i;
                      ref.read(settingsScrollToProvider.notifier).state = i;
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 9),
                      child: Row(
                        children: [
                          Icon(icon,
                              size: 17,
                              color: scheme.onSurface.withValues(alpha: 0.6)),
                          const SizedBox(width: 8),
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight:
                                  selected ? FontWeight.w600 : FontWeight.w400,
                              color: scheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
