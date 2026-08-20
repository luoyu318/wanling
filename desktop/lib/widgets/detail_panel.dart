import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/detail_panel_provider.dart';
import 'detail_changes_tab.dart';
import 'detail_info_tab.dart';

/// 详情侧栏面板:头部(标题 + 关闭)+ 信息/变更双 tab + 内容区。
///
/// 内容区用 IndexedStack 双 tab 同时挂载:切换不重建,变更 tab 的
/// sessionDiffProvider(autoDispose)在面板开期间保持存活,来回切 tab
/// 不重复拉取。挂载即 watch → 面板打开时才发起 session.diff 请求。
class DetailPanel extends ConsumerWidget {
  final String convId;
  final String? agentId;

  const DetailPanel({super.key, required this.convId, this.agentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final tab = ref.watch(detailPanelTabProvider);

    // Material 承载面板底色 + ExpansionTile/ListTile 的 ink(避免 ColoredBox
    // 包裹导致 "ink splashes may be invisible" 断言)
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部:标题 + 关闭
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerTheme.color ?? const Color(0xFFE4E4E4)),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '详情',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭详情',
                  icon: Icon(
                    Icons.close,
                    size: 18,
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                  onPressed: () =>
                      ref.read(detailPanelOpenProvider.notifier).state = false,
                ),
              ],
            ),
          ),
          // tab 行:信息 | 变更(选中下划线指示)
          Container(
            height: 40,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerTheme.color ?? const Color(0xFFE4E4E4)),
              ),
            ),
            child: Row(
              children: [
                _TabButton(
                  label: '信息',
                  selected: tab == DetailPanelTab.info,
                  onTap: () => ref.read(detailPanelTabProvider.notifier).state =
                      DetailPanelTab.info,
                ),
                _TabButton(
                  label: '变更',
                  selected: tab == DetailPanelTab.changes,
                  onTap: () => ref.read(detailPanelTabProvider.notifier).state =
                      DetailPanelTab.changes,
                ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: tab == DetailPanelTab.info ? 0 : 1,
              children: [
                DetailInfoTab(convId: convId, agentId: agentId),
                DetailChangesTab(convId: convId, agentId: agentId),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// tab 按钮:紧凑文字按钮,选中态主色 + 底部 2px 指示条。
class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected
                  ? scheme.primary
                  : scheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}
