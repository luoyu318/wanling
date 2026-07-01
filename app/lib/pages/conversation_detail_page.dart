import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/conversation.dart';
import '../models/participant.dart';
import '../providers/auth_provider.dart';
import '../providers/conversation_provider.dart';
import '../providers/participant_provider.dart';
import '../utils/snackbar.dart' show SnackBarType;
import '../widgets/avatar.dart';
import '../widgets/avatar_picker.dart';
import '../widgets/feedback/app_dialog.dart';
import '../widgets/feedback/app_snackbar.dart';
import '../widgets/settings_group.dart';
import '../widgets/settings_tile.dart';
import 'crop_avatar_page.dart';

/// 会话详情页：N 方 participants 模型的「群资料 / 1-1 资料」。
///
/// 内容：
/// - 顶部白底横幅 + 大头像 + 标题（群聊可编辑，1-1 只读）
/// - SettingsGroup「成员」:参与者列表(member_type icon + 名称 + role 徽章)
///   + 「邀请成员」按钮(本期占位)
/// - SettingsGroup「个人维度」:置顶 / 隐藏会话 toggle
/// - 底部「退出会话」红色按钮(群聊=退群/销群,1-1=删除会话)
///
/// 权限 UI：
/// - 群名 / 群头像编辑按钮仅在当前 user 是 owner/admin 时显示
/// - member 隐藏编辑入口
class ConversationDetailPage extends ConsumerStatefulWidget {
  final String convId;

  const ConversationDetailPage({super.key, required this.convId});

  @override
  ConsumerState<ConversationDetailPage> createState() =>
      _ConversationDetailPageState();
}

class _ConversationDetailPageState
    extends ConsumerState<ConversationDetailPage> {
  Conversation? _conv;
  bool _isLoading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadConversation();
  }

  Future<void> _loadConversation() async {
    try {
      final raw = await ref.read(apiProvider).getConversation(widget.convId);
      if (!mounted) return;
      setState(() {
        _conv = Conversation.fromJson(raw);
        _isLoading = false;
        _loadError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = '$e';
      });
    }
  }

  /// 当前 user id(用于在 participants 中找自己的 role)。
  String? get _currentUserId =>
      ref.read(authProvider).user?.id;

  /// 当前用户在该会话中的 participant 记录(可能为 null:理论上不该,
  /// 但 participants 还没刷新时兜底)。
  Participant? get _me {
    final uid = _currentUserId;
    if (uid == null) return null;
    final list = _conv?.participants ?? const [];
    for (final p in list) {
      if (p.memberType == 'user' && p.memberId == uid) return p;
    }
    return null;
  }

  /// 是否有群元信息编辑权限(owner / admin)。
  bool get _canEditGroup {
    final me = _me;
    if (me == null) return false;
    return me.isOwner || me.isAdmin;
  }

  /// 顶部展示名称:群聊用 title,1-1 用对端 participant.displayName 或 agent.name 兜底。
  String get _displayName {
    final conv = _conv;
    if (conv == null) return '';
    if (conv.isGroup) return conv.title?.isNotEmpty == true ? conv.title! : '未命名群聊';
    // 1-1:优先 agent summary(老 dm_user_agent),否则取 participants 中除自己外的第一个
    if (conv.agent != null) return conv.agent!.name;
    final uid = _currentUserId;
    final others = conv.participants
        .where((p) => !(p.memberType == 'user' && p.memberId == uid))
        .toList();
    if (others.isNotEmpty) return others.first.displayName;
    return '未知';
  }

  /// 顶部展示头像 URL:群用 avatarUrl,1-1 用对端头像。
  String? get _displayAvatarUrl {
    final conv = _conv;
    if (conv == null) return null;
    if (conv.isGroup) return conv.avatarUrl;
    if (conv.agent != null) return conv.agent!.avatarUrl;
    final uid = _currentUserId;
    final others = conv.participants
        .where((p) => !(p.memberType == 'user' && p.memberId == uid))
        .toList();
    if (others.isNotEmpty) {
      return others.first.avatarUrl.isNotEmpty ? others.first.avatarUrl : null;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_conv == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('加载失败', style: TextStyle(color: Color(0xFF999999))),
            if (_loadError != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  _loadError!,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(color: Color(0xFFB0B0B0), fontSize: 12),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                setState(() => _isLoading = true);
                _loadConversation();
              },
              child: const Text('重试'),
            ),
            TextButton(
              onPressed: () {
                if (context.canPop()) context.pop();
              },
              child: const Text('返回'),
            ),
          ],
        ),
      );
    }

    final conv = _conv!;
    final participants = ref.watch(participantProvider(widget.convId));
    // 用 participantProvider 拉到的最新 participants 覆盖 conv 内嵌的
    // (participantProvider 单独 GET /conversations/:id 后再次拉取,
    // 比 conversationProvider 内嵌更新鲜)。
    final displayParticipants =
        participants.isNotEmpty ? participants : conv.participants;

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF111111),
          title: const Text(''),
        ),
        SliverToBoxAdapter(child: _buildHeader(context, conv)),
        if (conv.isGroup) ...[
          SliverToBoxAdapter(
            child: SettingsGroup(
              children: [
                SettingsTile(
                  icon: Icons.edit_outlined,
                  label: '群名称',
                  trailing: Text(
                    conv.title?.isNotEmpty == true ? conv.title! : '未命名',
                    style: const TextStyle(
                        color: Color(0xFF999999), fontSize: 13),
                  ),
                  onTap: _canEditGroup
                      ? () => _editGroupTitle(context, conv)
                      : null,
                ),
                SettingsTile(
                  icon: Icons.photo_outlined,
                  label: '群头像',
                  showDivider: false,
                  onTap: _canEditGroup
                      ? () => _changeGroupAvatar(context, conv)
                      : null,
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: _ParticipantsSection(
              convId: widget.convId,
              participants: displayParticipants,
              currentUserId: _currentUserId,
              canManage: _canEditGroup,
              onInvite: _canEditGroup ? () => _inviteMember(context) : null,
            ),
          ),
        ] else ...[
          // 1-1 会话:不显示群资料 / 成员列表,只在底部展示「删除会话」。
        ],
        SliverToBoxAdapter(
          child: SettingsGroup(
            children: [
              SettingsTile(
                icon: conv.isPinned
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
                label: conv.isPinned ? '取消置顶' : '置顶会话',
                onTap: () => _togglePin(context, conv),
              ),
              SettingsTile(
                icon: Icons.visibility_off_outlined,
                label: '隐藏会话',
                showDivider: false,
                onTap: () => _confirmHide(context, conv),
              ),
            ],
          ),
        ),
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
                    backgroundColor: const Color(0xFFFA5151),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                  ),
                  onPressed: () => _confirmLeave(context, conv),
                  child: Text(
                    conv.isGroup ? '退出群聊' : '删除会话',
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 顶部白底横幅:大头像 + 名称 + (群聊)参与者数副标题。
  Widget _buildHeader(BuildContext context, Conversation conv) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 24),
      child: Row(
        children: [
          GestureDetector(
            onTap: (conv.isGroup && _canEditGroup)
                ? () => _changeGroupAvatar(context, conv)
                : null,
            child: Avatar(
              name: _displayName,
              url: _displayAvatarUrl,
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
                    Expanded(
                      child: Text(
                        _displayName,
                        style: const TextStyle(
                          color: Color(0xFF111111),
                          fontSize: 18,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (conv.isGroup && _canEditGroup)
                      IconButton(
                        icon: const Icon(Icons.edit,
                            size: 18, color: Color(0xFF999999)),
                        onPressed: () => _editGroupTitle(context, conv),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                  ],
                ),
                if (conv.isGroup) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${conv.participants.length} 位成员',
                    style: const TextStyle(
                        color: Color(0xFF999999), fontSize: 12),
                  ),
                ] else if (conv.type == 'dm_user_agent' &&
                    conv.agent != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Agent',
                    style: const TextStyle(
                        color: Color(0xFF999999), fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // === 操作 ===

  /// 修改群名:用 AppDialog + dismissOnConfirm:false 让 dialog 留住输入。
  /// 校验通过后手动 pop。校验失败(空名)留 dialog 不关,等用户改完。
  Future<void> _editGroupTitle(BuildContext context, Conversation conv) async {
    final ctrl = TextEditingController(text: conv.title ?? '');
    await showAppDialog(
      context: context,
      title: '修改群名称',
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(hintText: '输入群名称'),
      ),
      confirmText: '保存',
      dismissOnConfirm: false,
      onConfirm: () async {
        final title = ctrl.text.trim();
        if (title.isEmpty) return; // 空名留 dialog,等用户输入
        Navigator.of(context).pop();
        try {
          await ref
              .read(conversationProvider.notifier)
              .updateGroupProfile(widget.convId, title: title);
          await _loadConversation();
          if (mounted) {
            showAppSnackBar(context, '已更新', type: SnackBarType.success);
          }
        } catch (e) {
          if (mounted) {
            showAppSnackBar(context, '保存失败: $e', type: SnackBarType.error);
          }
        }
      },
    );
  }

  /// 换群头像:相册选图 → 裁剪 → 上传 → PATCH。
  Future<void> _changeGroupAvatar(
      BuildContext context, Conversation conv) async {
    final rawBytes = await pickImageBytes(context);
    if (rawBytes == null || !context.mounted) return;

    final croppedBytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => CropAvatarPage(rawBytes: rawBytes),
      ),
    );
    if (croppedBytes == null || !context.mounted) return;

    try {
      final api = ref.read(apiProvider);
      final fileId = await api.uploadBytes(croppedBytes, fileName: 'avatar.png');
      await ref
          .read(conversationProvider.notifier)
          .updateGroupProfile(widget.convId,
              avatarUrl: '/api/files/$fileId');
      await _loadConversation();
      if (context.mounted) {
        showAppSnackBar(context, '头像已更新', type: SnackBarType.success);
      }
    } catch (e) {
      if (context.mounted) {
        showAppSnackBar(context, '头像上传失败',
            type: SnackBarType.error);
      }
    }
  }

  /// 邀请成员:本期占位,Task 4.1 启用好友系统后接通。
  void _inviteMember(BuildContext context) {
    showAppSnackBar(context, '好友系统启用后将开放邀请',
        type: SnackBarType.info);
  }

  /// 置顶 / 取消置顶。
  Future<void> _togglePin(BuildContext context, Conversation conv) async {
    try {
      final notifier = ref.read(conversationProvider.notifier);
      if (conv.isPinned) {
        await notifier.unpin(conv.id);
      } else {
        await notifier.pin(conv.id);
      }
      await _loadConversation();
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, '操作失败: $e', type: SnackBarType.error);
      }
    }
  }

  /// 隐藏会话:二次确认后调 provider.hide + 退出详情页。
  void _confirmHide(BuildContext context, Conversation conv) {
    showAppDialog(
      context: context,
      title: '隐藏会话?',
      content: const Text('隐藏后将不在列表显示,有新消息时自动恢复。'),
      confirmText: '隐藏',
      onConfirm: () async {
        try {
          await ref.read(conversationProvider.notifier).hide(conv.id);
          if (context.mounted) {
            // pop 详情页,再 pop 一层 chat 页(若存在)。
            // 调用方一般在 ChatPage 内 push 进详情,隐藏会话后回不到 ChatPage,
            // 用 go('/') 直接到首页最稳妥。
            context.go('/');
          }
        } catch (e) {
          if (mounted) {
            showAppSnackBar(context, '隐藏失败: $e', type: SnackBarType.error);
          }
        }
      },
    );
  }

  /// 退群 / 销群 / 1-1 删除:二次确认。
  void _confirmLeave(BuildContext context, Conversation conv) {
    final isGroup = conv.isGroup;
    showAppDialog(
      context: context,
      title: isGroup ? '退出群聊?' : '删除会话?',
      content: Text(isGroup
          ? '退出后将不再接收此群消息。'
          : '删除后会话从列表消失,有新消息时自动恢复。'),
      confirmText: isGroup ? '退出' : '删除',
      onConfirm: () async {
        try {
          if (isGroup) {
            await ref
                .read(conversationProvider.notifier)
                .leaveConversation(conv.id);
          } else {
            await ref.read(conversationProvider.notifier).hide(conv.id);
          }
          if (context.mounted) context.go('/');
        } catch (e) {
          if (mounted) {
            showAppSnackBar(context, '操作失败: $e',
                type: SnackBarType.error);
          }
        }
      },
    );
  }
}

/// 成员列表区块。独立 widget 让 _ConversationDetailPageState.build 不会因
/// participants 变长而嵌套太深。
///
/// ConsumerWidget 让 kick 能调 participantProvider(自刷新参与者列表)。
class _ParticipantsSection extends ConsumerWidget {
  final String convId;
  final List<Participant> participants;
  final String? currentUserId;
  final bool canManage;
  final VoidCallback? onInvite;

  const _ParticipantsSection({
    required this.convId,
    required this.participants,
    required this.currentUserId,
    required this.canManage,
    required this.onInvite,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final children = <Widget>[
      // 段落标题
      Container(
        color: Colors.white,
        padding: const EdgeInsets.only(left: 16, top: 12, bottom: 4),
        child: Text(
          '成员 (${participants.length})',
          style: const TextStyle(
              color: Color(0xFF999999), fontSize: 12),
        ),
      ),
    ];

    if (participants.isEmpty) {
      children.add(
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
          child: const Center(
            child: Text('暂无成员',
                style: TextStyle(color: Color(0xFF999999), fontSize: 13)),
          ),
        ),
      );
    } else {
      for (var i = 0; i < participants.length; i++) {
        final p = participants[i];
        children.add(_ParticipantTile(
          participant: p,
          isMe: p.memberType == 'user' && p.memberId == currentUserId,
          canKick: canManage &&
              !p.isOwner &&
              !(p.memberType == 'user' && p.memberId == currentUserId),
          onKick: () => _confirmKick(context, ref, p),
          showDivider: i != participants.length - 1,
        ));
      }
    }

    if (onInvite != null) {
      children.add(Container(
        color: Colors.white,
        padding: const EdgeInsets.only(top: 8),
        child: SettingsTile(
          icon: Icons.person_add_outlined,
          label: '邀请成员',
          showDivider: false,
          onTap: onInvite,
        ),
      ));
    }

    return Container(
      margin: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  void _confirmKick(BuildContext context, WidgetRef ref, Participant p) {
    showAppDialog(
      context: context,
      title: '移除成员?',
      content: Text('将 ${p.displayName} 移出群聊。'),
      confirmText: '移除',
      onConfirm: () async {
        try {
          await ref.read(participantProvider(convId).notifier).kick(p.memberId);
          if (context.mounted) {
            showAppSnackBar(context, '已移除', type: SnackBarType.success);
          }
        } catch (e) {
          if (context.mounted) {
            showAppSnackBar(context, '移除失败: $e', type: SnackBarType.error);
          }
        }
      },
    );
  }
}

/// 单个参与者行。带 role 徽章(owner=金 / admin=蓝 / member 无)。
class _ParticipantTile extends StatelessWidget {
  final Participant participant;
  final bool isMe;
  final bool canKick;
  final VoidCallback? onKick;
  final bool showDivider;

  const _ParticipantTile({
    required this.participant,
    required this.isMe,
    required this.canKick,
    required this.onKick,
    required this.showDivider,
  });

  @override
  Widget build(BuildContext context) {
    final p = participant;
    final icon = p.isAgent ? Icons.smart_toy_outlined : Icons.person_outline;
    final roleBadge = _roleBadge(p.role);

    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: canKick ? onKick : null,
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Avatar(
                    name: p.displayName,
                    url: p.avatarUrl.isNotEmpty ? p.avatarUrl : null,
                    size: 36,
                    radius: 6,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isMe ? '${p.displayName} (我)' : p.displayName,
                      style: const TextStyle(
                        fontSize: 15,
                        color: Color(0xFF333333),
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ),
                  if (roleBadge != null) ...[
                    roleBadge,
                    const SizedBox(width: 8),
                  ],
                  Icon(icon, size: 18, color: const Color(0xFFB0B0B0)),
                ],
              ),
            ),
            if (showDivider)
              Container(
                height: 0.5,
                color: Colors.white,
                child: Container(
                  margin: const EdgeInsets.only(left: 64),
                  color: const Color(0xFFE4E4E4),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// role 徽章:owner 金 / admin 蓝 / member 不显示。
  Widget? _roleBadge(String role) {
    switch (role) {
      case 'owner':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFE6A23C),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            '群主',
            style: TextStyle(color: Colors.white, fontSize: 10),
          ),
        );
      case 'admin':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFF5B8BF7),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            '管理员',
            style: TextStyle(color: Colors.white, fontSize: 10),
          ),
        );
      default:
        return null;
    }
  }
}
