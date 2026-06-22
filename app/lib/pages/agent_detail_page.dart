import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'crop_avatar_page.dart';
import '../models/agent.dart';
import '../providers/agent_provider.dart';
import '../providers/auth_provider.dart' show apiProvider;
import '../providers/conversation_provider.dart';
import '../router_helpers.dart';
import '../utils/snackbar.dart';
import '../widgets/avatar.dart';
import '../widgets/avatar_picker.dart';
import '../widgets/copyable_field.dart';

/// Agent 详情页：IM 个人资料风格（A 布局）。
/// - 顶部品牌色横幅 + 大头像 + 名称/状态
/// - 分组卡片：AppID + 密钥（眼睛切换 + 复制）
/// - 分组卡片：编辑昵称、删除 Agent
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
          // 顶部品牌色横幅，pinned 让标题区域固定。
          SliverAppBar(
            pinned: true,
            backgroundColor: const Color(0xFF7BB242),
            foregroundColor: Colors.white,
            title: const Text(''),
          ),
          SliverToBoxAdapter(
            child: Container(
              color: const Color(0xFF7BB242),
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
                        Text(
                          agent.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          agent.status == AgentStatus.online ? '在线' : '离线',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                        if (agent.bio != null && agent.bio!.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            agent.bio!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // AppID + 密钥卡片
          SliverToBoxAdapter(
            child: Container(
              color: Colors.white,
              margin: const EdgeInsets.only(top: 8),
              child: Column(
                children: [
                  CopyableField(label: 'AppID', value: agent.id),
                  const Divider(height: 1, color: Color(0xFFF0F0F0)),
                  // secretKey 可能是 null（后端 omitempty），CopyableField value 不能为 null，用 ?? ''
                  CopyableField(label: '密钥', value: agent.secretKey ?? '', secret: true),
                ],
              ),
            ),
          ),
          // 操作：编辑昵称、删除 Agent
          SliverToBoxAdapter(
            child: Container(
              color: Colors.white,
              margin: const EdgeInsets.only(top: 8),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.edit_outlined, size: 20),
                    title: const Text('编辑资料', style: TextStyle(fontSize: 14)),
                    trailing: const Icon(Icons.chevron_right, color: Color(0xFFC0C0C0)),
                    onTap: () => _editProfile(context, ref, agent),
                  ),
                  const Divider(height: 1, indent: 56, color: Color(0xFFF0F0F0)),
                  ListTile(
                    leading: const Icon(Icons.delete_outline, color: Color(0xFFFA5151), size: 20),
                    title: const Text('删除 Agent',
                        style: TextStyle(fontSize: 14, color: Color(0xFFFA5151))),
                    onTap: () => _delete(context, ref, agent),
                  ),
                ],
              ),
            ),
          ),
          // 底部"发消息" CTA：用 SliverFillRemaining 把按钮顶到可视区底部
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
                    onPressed: () => startChatAndPush(context, ref, agent),
                    child: const Text('发消息', style: TextStyle(fontSize: 15)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 编辑昵称 + 简介：弹出对话框，两个输入框，统一保存。
  void _editProfile(BuildContext context, WidgetRef ref, Agent agent) {
    final nameCtrl = TextEditingController(text: agent.name);
    final bioCtrl = TextEditingController(text: agent.bio ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑资料'),
        content: Column(
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
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await ref.read(agentListProvider.notifier).update(
                      agent.id,
                      name: nameCtrl.text.trim(),
                      bio: bioCtrl.text.trim(),
                    );
                if (ctx.mounted) Navigator.pop(ctx);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx)
                      .showSnackBar(SnackBar(content: Text('修改失败: $e')));
                }
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// 点击头像换图：相册选图 → 裁剪页 → 上传 → update(avatarUrl) 即时刷新。
  /// AgentDetailPage 是 ConsumerWidget（无 StatefulState），用 context.mounted。
  Future<void> _changeAvatar(
      BuildContext context, WidgetRef ref, Agent agent) async {
    // 1. 相册选图
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
          await api.uploadBytes(croppedBytes, fileName: 'avatar.png');
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
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('删除 ${agent.name} 后将无法恢复，且相关会话也会被删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFA5151)),
            onPressed: () async {
              try {
                await ref.read(agentListProvider.notifier).delete(agent.id);
                // 联动移除消息 tab 中该 agent 的会话
                ref.read(conversationProvider.notifier).removeByAgentId(agent.id);
                if (!ctx.mounted) return;
                Navigator.pop(ctx); // 关闭 dialog
                if (context.mounted) context.pop(); // 退出详情页回列表
              } catch (e) {
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('删除失败: $e')));
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
