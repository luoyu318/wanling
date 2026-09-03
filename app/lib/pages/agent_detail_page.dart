
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'crop_avatar_page.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/agent_type_info.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_types_provider.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/conversation_provider.dart';
import '../router_helpers.dart';
import 'package:wanling_core/utils/snackbar.dart';
import '../widgets/agent_badge.dart';
import '../widgets/app_dropdown_field.dart';
import '../widgets/avatar.dart';
import '../widgets/avatar_picker.dart';
import '../widgets/copyable_field.dart';
import '../widgets/feedback/app_dialog.dart';
import '../widgets/settings_group.dart';
import '../widgets/settings_tile.dart';

/// Agent 详情页：IM 个人资料风格（A 布局）。
/// - 顶部白底横幅 + 大头像 + 名称/状态
/// - 分组卡片：AppID + 密钥（眼睛切换 + 复制）
/// - 分组卡片：编辑昵称、删除 Agent（SettingsTile）
/// - 底部"发消息" CTA
///
/// 删除后联动 conversationProvider 移除相关会话并 pop 回列表。
class AgentDetailPage extends ConsumerWidget {
  final String agentId;
  const AgentDetailPage({super.key, required this.agentId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agents = ref.watch(agentListProvider);
    final agent = agents.where((a) => a.id == agentId).firstOrNull;

    if (agent == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Agent 详情')),
        body: const Center(child: Text('Agent 不存在')),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      body: CustomScrollView(
        slivers: [
          // 顶部白底横幅，pinned 让标题区域固定。
          const SliverAppBar(
            pinned: true,
            backgroundColor: Colors.white,
            foregroundColor: Color(0xFF111111),
            title: Text(''),
          ),
          SliverToBoxAdapter(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.only(left: 16, right: 16, bottom: 24),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => _changeAvatar(context, ref, agent),
                    child: Avatar(
                      name: agent.name,
                      url: agent.avatarUrl,
                      size: 60,
                      radius: 8,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                agent.name,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF111111),
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            AgentBadge(type: agent.type),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: agent.status == AgentStatus.online
                                    ? const Color(0xFF07C160)
                                    : const Color(0xFF999999),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              agent.status == AgentStatus.online ? '在线' : '离线',
                              style: TextStyle(
                                color: agent.status == AgentStatus.online
                                    ? const Color(0xFF07C160)
                                    : const Color(0xFF999999),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        if (agent.bio != null && agent.bio!.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            agent.bio!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Color(0xFF999999), fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // AppID 卡片(密钥不展示,改为下方"重置密钥"操作)。
          // 密钥仅创建时一次性下发,List/Get 永不返回;放展示位必为空,无意义。
          SliverToBoxAdapter(
            child: Container(
              color: Colors.white,
              margin: const EdgeInsets.only(top: 8),
              child: Column(
                children: [
                  CopyableField(label: 'AppID', value: agent.id),
                ],
              ),
            ),
          ),
          // 操作：编辑资料、重置密钥、删除 Agent（公共 SettingsTile，统一按下反馈 + 分割线）
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.edit_outlined,
                  label: '编辑资料',
                  onTap: () => _editProfile(context, ref, agent),
                ),
                // 授权密钥(子密钥):REST-only 授权,不重置主密钥。
                // 放「重置密钥」前:轻量管理操作优先,破坏性操作垫底。
                SettingsTile(
                  icon: Icons.key_outlined,
                  label: '授权密钥',
                  onTap: () => context.push(subKeysRoute(agent.id)),
                ),
                SettingsTile(
                  icon: Icons.vpn_key_outlined,
                  label: '重置密钥',
                  onTap: () => _rotateSecret(context, ref, agent),
                ),
                SettingsTile(
                  icon: Icons.delete_outline,
                  label: '删除 Agent',
                  labelColor: const Color(0xFFFA5151),
                  iconColor: const Color(0xFFFA5151),
                  showDivider: false,
                  onTap: () => _delete(context, ref, agent),
                ),
              ],
            ),
          ),
          // 底部 CTA:用 SliverFillRemaining 把按钮顶到可视区底部。
          // 多 session 开发型(opencode 类)→ 进二级 session 群列表;对话型 → 发消息(单聊)。
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Align(
                alignment: Alignment.bottomCenter,
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF07C160),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                    ),
                    onPressed: () {
                      if (agent.isMultiSession) {
                        context.push(sessionsRoute(agent.id));
                      } else {
                        startChatAndPush(context, ref, agent);
                      }
                    },
                    child: Text(
                      agent.isMultiSession ? '进入会话' : '发消息',
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 重置密钥:二次确认 → 调 API → 一次性弹窗展示新密钥(带复制按钮)。
  /// 用户点"我已保存"关闭后,新密钥永远不再可见(对齐 GitHub PAT 模式)。
  void _rotateSecret(BuildContext context, WidgetRef ref, Agent agent) {
    showAppDialog(
      context: context,
      title: '重置密钥',
      content: const Text(
        '重置密钥后旧连接立即失效，需用新密钥重新配置 Agent 终端。'
        '新密钥仅在此刻展示一次，请立即保存。',
      ),
      confirmText: '确定重置',
      onConfirm: () async {
        try {
          final newKey = await ref
              .read(agentListProvider.notifier)
              .rotateSecretKey(agent.id);
          if (!context.mounted) return;
          _showNewSecretDialog(context, newKey);
        } catch (e) {
          if (context.mounted) {
            showAppSnackBar(context, '重置失败: $e', type: SnackBarType.error);
          }
        }
      },
    );
  }

  /// 一次性展示新密钥:复制按钮 + "我已保存"关闭。
  void _showNewSecretDialog(BuildContext context, String newKey) {
    showAppDialog(
      context: context,
      title: '新密钥(仅展示一次)',
      content: _NewSecretContent(secretKey: newKey),
      confirmText: '我已保存',
      onConfirm: () {},
    );
  }

  /// 编辑昵称 + 简介 + 类型：弹出对话框，统一保存。
  void _editProfile(BuildContext context, WidgetRef ref, Agent agent) {
    final nameCtrl = TextEditingController(text: agent.name);
    final bioCtrl = TextEditingController(text: agent.bio ?? '');
    String agentType = agent.type;
    showAppDialog(
      context: context,
      title: '编辑资料',
      content: StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '昵称'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: bioCtrl,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(labelText: '简介'),
            ),
            const SizedBox(height: 8),
            AppDropdownFormField<String>(
              value: agentType,
              label: '类型',
              // 类型清单来自 server 注册表(GET /api/agent-types):新类型
              // server 侧登记后自动出现,APP 零发版。老 server/加载失败
              // fallback 本地预置三类。
              items: () {
                final types = _typeOptions(ref);
                return [
                  const AppDropdownItem(value: '', label: '普通'),
                  ...types.map(
                      (t) => AppDropdownItem(value: t.type, label: t.label)),
                  // 未注册类型兜底 item:防 value 匹配不到触发断言崩溃。
                  if (agentType.isNotEmpty &&
                      !types.any((t) => t.type == agentType))
                    AppDropdownItem(value: agentType, label: agentType),
                ];
              }(),
              onChanged: (v) => setState(() => agentType = v ?? ''),
            ),
          ],
        ),
      ),
      confirmText: '保存',
      onConfirm: () async {
        try {
          await ref.read(agentListProvider.notifier).update(
                agent.id,
                name: nameCtrl.text.trim(),
                bio: bioCtrl.text.trim(),
                type: agentType,
              );
        } catch (e) {
          if (context.mounted) {
            showAppSnackBar(context, '修改失败: $e', type: SnackBarType.error);
          }
        }
      },
    );
  }

  /// 点击头像换图：相册选图 → 裁剪页 → 上传 → update(avatarUrl) 即时刷新。
  /// AgentDetailPage 是 ConsumerWidget（无 StatefulState），用 context.mounted。
  Future<void> _changeAvatar(
      BuildContext context, WidgetRef ref, Agent agent) async {
    // 1. 相册选图（返回原始字节，HEIC 转码由裁剪页内承担，避免回上一页等转码）
    final rawBytes = await pickImageBytes(context);
    if (rawBytes == null || !context.mounted) return; // 用户取消

    // 2. 跳裁剪页
    final croppedBytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => CropAvatarPage(rawBytes: rawBytes),
      ),
    );
    if (croppedBytes == null || !context.mounted) return; // 用户取消裁剪

    // 3. 上传 + 刷新
    try {
      final api = ref.read(apiProvider);
      final fileId =
          await api.uploadBytes(croppedBytes, fileName: 'avatar.jpg');
      await ref.read(agentListProvider.notifier)
          .update(agent.id, avatarUrl: '/api/files/$fileId');
      if (context.mounted) {
        showAppSnackBar(context, '头像已更新', type: SnackBarType.success);
      }
    } catch (e, st) {
      // 上传失败原因（nginx 413 / 网络断 / 服务端 500 等）打印到控制台，
      // 方便 adb logcat 定位；用户只看到通用文案。
      debugPrint('Agent 头像上传失败: $e\n$st');
      if (context.mounted) {
        showAppSnackBar(context, '头像上传失败，请重试', type: SnackBarType.error);
      }
    }
  }

  /// 删除 Agent：二次确认，成功后联动移除消息 tab 中相关会话并 pop 两次
  /// （dialog + 详情页）。
  void _delete(BuildContext context, WidgetRef ref, Agent agent) {
    showAppDialog(
      context: context,
      title: '确认删除',
      content: Text('删除 ${agent.name} 后将无法恢复，且相关会话也会被删除。'),
      confirmText: '删除',
      onConfirm: () async {
        try {
          await ref.read(agentListProvider.notifier).delete(agent.id);
          // 联动移除消息 tab 中该 agent 的会话
          ref.read(conversationProvider.notifier).removeByAgentId(agent.id);
          if (context.mounted) context.pop(); // 退出详情页回列表
        } catch (e) {
          if (context.mounted) {
            showAppSnackBar(context, '删除失败: $e', type: SnackBarType.error);
          }
        }
      },
    );
  }
}

/// 新密钥一次性展示内容:密钥文本(可选中) + 复制按钮。
class _NewSecretContent extends StatefulWidget {
  final String secretKey;
  const _NewSecretContent({required this.secretKey});

  @override
  State<_NewSecretContent> createState() => _NewSecretContentState();
}

class _NewSecretContentState extends State<_NewSecretContent> {
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F5F5),
            borderRadius: BorderRadius.circular(4),
          ),
          child: SelectableText(
            widget.secretKey,
            style: const TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: Color(0xFF333333),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.copy, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.secretKey));
                setState(() => _copied = true);
              },
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? '已复制' : '复制',
              style: const TextStyle(fontSize: 13, color: Color(0xFF07C160)),
            ),
          ],
        ),
      ],
    );
  }
}

/// 类型下拉数据源:server 注册表优先,老 server/加载失败 fallback 本地预置。
/// 放顶层函数供「详情改类型」「新建 agent」两处下拉共用。
List<AgentTypeInfo> _typeOptions(WidgetRef ref) =>
    ref.read(agentTypesProvider).valueOrNull?.isNotEmpty == true
        ? ref.read(agentTypesProvider).valueOrNull!
        : AgentTypeInfo.fallbackTypes;
