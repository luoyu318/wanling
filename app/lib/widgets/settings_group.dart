import 'package:flutter/material.dart';

/// 白底卡片容器，包裹一组 [SettingsTile]（或其他行元素）。
///
/// 顶部默认 8px margin（与 ProfilePage / AgentDetailPage 的卡片间距一致）。
/// 内部 Column 让子元素垂直排列，背景统一白底。
class SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets margin;

  const SettingsGroup({
    super.key,
    required this.children,
    this.margin = const EdgeInsets.only(top: 8),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('settings-group'),
      margin: margin,
      decoration: const BoxDecoration(color: Colors.white),
      child: Column(children: children),
    );
  }
}
