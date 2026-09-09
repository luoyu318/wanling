// 从 templates/flutter-page.dart.tmpl 骨架裁剪:纯静态菜单页无数据加载,
// 模板的 loading/error 三态不适用;沿用 const+key(审计 L2/S2)规则。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:wanling_core/providers/inbox_popup_pref_provider.dart';
import 'package:wanling_core/theme/app_colors.dart';

import '../utils/permission_helper.dart';
import '../widgets/settings_group.dart';
import '../widgets/settings_tile.dart';

/// 设置页:账号(编辑资料/修改密码) + 通知与偏好(通知与后台/自动弹出审批·问答)。
/// 菜单自侧滑栏迁入(spec 2026-09-09-app-settings-page-design),侧滑栏头部
/// 点击仍直达编辑资料。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key}); // const + key(审计 L2/S2)

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          const _GroupLabel('账号'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.person,
                iconColor: const Color(0xFF2F6BFF),
                label: '编辑资料',
                showDivider: false,
                showChevron: false,
                onTap: () => context.push('/profile/edit'),
              ),
              SettingsTile(
                icon: Icons.lock,
                iconColor: const Color(0xFF00B578),
                label: '修改密码',
                showDivider: false,
                showChevron: false,
                onTap: () => context.push('/change-password'),
              ),
            ],
          ),
          const _GroupLabel('通知与偏好'),
          SettingsGroup(
            children: [
              SettingsTile(
                icon: Icons.notifications,
                iconColor: const Color(0xFFFF9500),
                label: '通知与后台',
                showDivider: false,
                showChevron: false,
                onTap: () => PermissionHelper.openAppNotificationSettings(),
              ),
              // 审批/问答抽屉自动弹出开关:纯本地偏好,只拦全局抽屉自动弹,
              // 卡片仍进消息流与收件箱队列(spec 2026-09-09-inbox-auto-popup-toggle)。
              SettingsTile(
                icon: Icons.inbox,
                iconColor: const Color(0xFF5AC8FA),
                label: '自动弹出审批/问答',
                subtitle: '关闭后卡片仍在会话内，需进入会话处理',
                showDivider: false,
                showChevron: false,
                trailing: Switch(
                  key: const ValueKey('inbox-auto-popup-switch'),
                  value: ref.watch(inboxPopupPrefProvider),
                  // 写失败由 provider set 先回滚 state 再抛,Switch 随 watch 弹回
                  // 真实持久态;这里显式 unawaited 标注丢弃 Future(失败不静默)。
                  onChanged: (v) => unawaited(
                      ref.read(inboxPopupPrefProvider.notifier).set(v)),
                ),
                onTap: () => unawaited(ref
                    .read(inboxPopupPrefProvider.notifier)
                    .set(!ref.read(inboxPopupPrefProvider))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 分组标题:灰字小号,组外左侧 16px(与 SettingsTile 图标对齐)。
class _GroupLabel extends StatelessWidget {
  final String text;
  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
