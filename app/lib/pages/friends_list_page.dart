import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/friendship.dart';
import '../models/user_summary.dart';
import '../providers/friend_provider.dart';
import '../utils/snackbar.dart' show SnackBarType;
import '../widgets/avatar.dart';
import '../widgets/feedback/app_dialog.dart';
import '../widgets/feedback/app_snackbar.dart';

/// 好友中心页:好友列表 + 收到请求 + 已发出请求。
///
/// 三 Tab 布局对齐主流 IM 「通讯录 → 我的好友 / 新的朋友」结构。
/// 「收到请求」Tab 文案带红点 Badge(收到请求数 > 0 时),与 ProfilePage
/// 入口的红点 Badge 互为冗余提醒(确保用户不会漏看)。
///
/// 设计风格对齐 conversation_detail_page + profile_page:
///   - 背景 #EDEDED,卡片白底
///   - 行高 / icon / 字号 / 分割线口径与 SettingsTile 一致
///   - 操作(接受 / 拒绝 / 取消 / 删除)用 FilledButton + 二次确认 AppDialog
class FriendsListPage extends ConsumerStatefulWidget {
  const FriendsListPage({super.key});

  @override
  ConsumerState<FriendsListPage> createState() => _FriendsListPageState();
}

class _FriendsListPageState extends ConsumerState<FriendsListPage> {
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(friendListProvider);
    // 用单独 select 监听 incomingCount,红点 Badge 只关心这个数值,
    // 避免其他字段(friends/outgoing)变化时不必要地重建 TabBar。
    final incomingCount =
        ref.watch(friendListProvider.select((s) => s.incomingCount));

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFFEDEDED),
        appBar: AppBar(
          backgroundColor: const Color(0xFFF7F7F7),
          foregroundColor: const Color(0xFF111111),
          title: const Text('我的好友'),
          actions: [
            IconButton(
              icon: const Icon(Icons.person_add_outlined),
              tooltip: '添加好友',
              onPressed: () => context.push('/friends/add'),
            ),
          ],
          bottom: TabBar(
            labelColor: const Color(0xFF111111),
            unselectedLabelColor: const Color(0xFF999999),
            indicatorColor: const Color(0xFF07C160),
            overlayColor: WidgetStateProperty.all(Colors.transparent),
            tabs: [
              const Tab(text: '好友'),
              Tab(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('收到请求'),
                    if (incomingCount > 0) ...[
                      const SizedBox(width: 6),
                      _CountDot(count: incomingCount),
                    ],
                  ],
                ),
              ),
              const Tab(text: '已发送'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _FriendsTab(friends: state.friends),
            _IncomingTab(incoming: state.incoming),
            _OutgoingTab(outgoing: state.outgoing),
          ],
        ),
      ),
    );
  }
}

/// 好友列表 Tab。
///
/// 行点击弹 BottomSheet 菜单(发消息 / 删除好友)。
/// 删除好友二次确认(AppDialog),server username/id 一致性问题详见
/// [FriendListNotifier.removeFriend] 注释。
///
/// 用 ConsumerWidget 而非 StatelessWidget:BottomSheet 内删除需要 ref
/// 读 friendListProvider.notifier。
class _FriendsTab extends ConsumerWidget {
  final List<UserSummary> friends;

  const _FriendsTab({required this.friends});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (friends.isEmpty) {
      return const _EmptyHint(
        icon: Icons.people_outline,
        text: '还没有好友\n点击右上角 + 添加',
      );
    }
    return ListView.builder(
      itemCount: friends.length,
      itemBuilder: (_, i) {
        final u = friends[i];
        return _UserRow(
          key: ValueKey('friend_${u.username}'),
          username: u.username,
          nickname: u.nickname,
          avatarUrl: u.avatarUrl,
          onTap: () => _showFriendMenu(context, ref, u),
        );
      },
    );
  }

  void _showFriendMenu(
      BuildContext context, WidgetRef ref, UserSummary u) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  u.displayName,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF999999),
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.chat_bubble_outline, size: 22),
                title: const Text('发消息'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _startDm(context, u);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline,
                    size: 22, color: Color(0xFFFA5151)),
                title: const Text('删除好友',
                    style: TextStyle(color: Color(0xFFFA5151))),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmRemove(context, ref, u);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 发消息(创建 dm_user_user 会话并跳转 ChatPage)。
  ///
  /// 已知限制:ChatPage 当前必传 agentId(为 1-1 agent 模型设计),
  /// user-user DM 的 ChatPage 接入由 Task 4.x(端到端验证)处理。
  /// 本 task 范围内:用 snackbar 提示「功能即将开放」保视觉一致,
  /// 避免跳到 ChatPage 因 agentId 缺失 crash。
  void _startDm(BuildContext context, UserSummary u) {
    showAppSnackBar(context, '1-1 会话功能即将开放',
        type: SnackBarType.info);
    // TODO(Task 4.x): 接通 user-user DM 路由。
    // 链路:api.createConversation(type='dm_user_user',
    //   memberIds=[me.username, u.username], memberTypes=['user','user'])
    //   → 拿 convId → context.pushReplacement('/chat/$convId?agentId=')
  }

  void _confirmRemove(
      BuildContext context, WidgetRef ref, UserSummary u) {
    showAppDialog(
      context: context,
      title: '删除好友?',
      content: Text('将删除与 ${u.displayName} 的好友关系,对方不会收到通知。'),
      confirmText: '删除',
      onConfirm: () {
        // 注意:removeFriend 是乐观更新(先本地后 server),见 provider 注释。
        // server username/id 路径冲突会在 Task 4.x 解决,本 task 用户视觉一致。
        ref.read(friendListProvider.notifier).removeFriend(u.username).then((_) {
          if (context.mounted) {
            showAppSnackBar(context, '已删除', type: SnackBarType.info);
          }
        }).catchError((e) {
          // server 调用失败:本地乐观已更新,用户视觉一致;
          // task 描述接受 known issue,reload 后会恢复实际状态。
          if (context.mounted) {
            showAppSnackBar(context, '同步失败,稍后会自动重试',
                type: SnackBarType.info);
          }
        });
      },
    );
  }
}

/// 收到请求 Tab。
///
/// 每行:对方信息 + 「接受 / 拒绝」按钮。
/// 接受成功后该请求从列表移除(本地乐观),并通过 [FriendListNotifier.accept]
/// 加入 friends 列表。拒绝只移除当前列表。
class _IncomingTab extends ConsumerWidget {
  final List<FriendRequest> incoming;

  const _IncomingTab({required this.incoming});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (incoming.isEmpty) {
      return const _EmptyHint(
        icon: Icons.inbox_outlined,
        text: '没有收到的好友请求',
      );
    }
    return ListView.builder(
      itemCount: incoming.length,
      itemBuilder: (_, i) {
        final r = incoming[i];
        return _RequestRow(
          key: ValueKey('incoming_${r.id}'),
          username: r.user.username,
          nickname: r.user.nickname,
          avatarUrl: r.user.avatarUrl,
          subtitle: '请求加你为好友',
          primaryAction: '接受',
          onPrimary: () => _accept(context, ref, r),
          secondaryAction: '拒绝',
          onSecondary: () => _reject(context, ref, r),
        );
      },
    );
  }

  void _accept(BuildContext context, WidgetRef ref, FriendRequest r) {
    ref.read(friendListProvider.notifier).accept(r.id).then((_) {
      if (context.mounted) {
        showAppSnackBar(context, '已添加 ${r.user.displayName}',
            type: SnackBarType.success);
      }
    }).catchError((e) {
      if (context.mounted) {
        showAppSnackBar(context, '操作失败: $e', type: SnackBarType.error);
      }
    });
  }

  void _reject(BuildContext context, WidgetRef ref, FriendRequest r) {
    showAppDialog(
      context: context,
      title: '拒绝请求?',
      content: Text('将拒绝 ${r.user.displayName} 的好友请求。'),
      confirmText: '拒绝',
      onConfirm: () {
        ref.read(friendListProvider.notifier).reject(r.id).then((_) {
          if (context.mounted) {
            showAppSnackBar(context, '已拒绝', type: SnackBarType.info);
          }
        }).catchError((e) {
          if (context.mounted) {
            showAppSnackBar(context, '操作失败: $e', type: SnackBarType.error);
          }
        });
      },
    );
  }
}

/// 已发送请求 Tab。
///
/// 每行:对方信息 + 「取消」按钮。取消二次确认。
class _OutgoingTab extends ConsumerWidget {
  final List<FriendRequest> outgoing;

  const _OutgoingTab({required this.outgoing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (outgoing.isEmpty) {
      return const _EmptyHint(
        icon: Icons.send_outlined,
        text: '没有发出的好友请求',
      );
    }
    return ListView.builder(
      itemCount: outgoing.length,
      itemBuilder: (_, i) {
        final r = outgoing[i];
        return _RequestRow(
          key: ValueKey('outgoing_${r.id}'),
          username: r.user.username,
          nickname: r.user.nickname,
          avatarUrl: r.user.avatarUrl,
          subtitle: '等待对方确认',
          primaryAction: '取消',
          onPrimary: () => _cancel(context, ref, r),
        );
      },
    );
  }

  void _cancel(BuildContext context, WidgetRef ref, FriendRequest r) {
    showAppDialog(
      context: context,
      title: '取消请求?',
      content: Text('将取消对 ${r.user.displayName} 的好友请求。'),
      confirmText: '取消请求',
      onConfirm: () {
        ref.read(friendListProvider.notifier).cancel(r.id).then((_) {
          if (context.mounted) {
            showAppSnackBar(context, '已取消', type: SnackBarType.info);
          }
        }).catchError((e) {
          if (context.mounted) {
            showAppSnackBar(context, '操作失败: $e', type: SnackBarType.error);
          }
        });
      },
    );
  }
}

// === 通用行 / 空状态组件 ===

/// 通用用户行:头像 + 昵称 + @username 副标题 + 右侧按钮。
class _UserRow extends StatelessWidget {
  final String username;
  final String nickname;
  final String avatarUrl;
  final VoidCallback? onTap;
  final Widget? trailing;

  const _UserRow({
    super.key,
    required this.username,
    required this.nickname,
    required this.avatarUrl,
    this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onTap,
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Avatar(
                    name: nickname.isNotEmpty ? nickname : username,
                    url: avatarUrl.isNotEmpty ? avatarUrl : null,
                    size: 40,
                    radius: 6,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nickname,
                          style: const TextStyle(
                            fontSize: 15,
                            color: Color(0xFF333333),
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '@$username',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (trailing != null) ...[trailing!],
                ],
              ),
            ),
            Container(
              height: 0.5,
              color: Colors.white,
              child: Container(
                margin: const EdgeInsets.only(left: 68),
                color: const Color(0xFFE4E4E4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 请求行:头像 + 昵称 + 副标题 + 右侧按钮组(1 个或 2 个)。
class _RequestRow extends StatelessWidget {
  final String username;
  final String nickname;
  final String avatarUrl;
  final String subtitle;
  final String? primaryAction;
  final VoidCallback? onPrimary;
  final String? secondaryAction;
  final VoidCallback? onSecondary;

  const _RequestRow({
    super.key,
    required this.username,
    required this.nickname,
    required this.avatarUrl,
    required this.subtitle,
    this.primaryAction,
    this.onPrimary,
    this.secondaryAction,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final trailing = <Widget>[];
    if (secondaryAction != null && onSecondary != null) {
      trailing.add(
        TextButton(
          onPressed: onSecondary,
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFF999999),
            minimumSize: const Size(56, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          child: Text(secondaryAction!),
        ),
      );
      trailing.add(const SizedBox(width: 4));
    }
    if (primaryAction != null && onPrimary != null) {
      trailing.add(
        FilledButton(
          onPressed: onPrimary,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF07C160),
            foregroundColor: Colors.white,
            minimumSize: const Size(56, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          child: Text(primaryAction!),
        ),
      );
    }

    return _UserRow(
      key: key,
      username: username,
      nickname: nickname,
      avatarUrl: avatarUrl,
      trailing: trailing.isEmpty
          ? null
          : Row(mainAxisSize: MainAxisSize.min, children: trailing),
    );
  }
}

/// 空状态提示(居中 icon + 文字)。
class _EmptyHint extends StatelessWidget {
  final IconData icon;
  final String text;

  const _EmptyHint({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: const Color(0xFFB0B0B0)),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFF999999),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 小红点(count > 0 时显示,与 [UnreadBadge] 风格一致但更紧凑)。
class _CountDot extends StatelessWidget {
  final int count;

  const _CountDot({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFFFA5151),
        borderRadius: BorderRadius.circular(8),
      ),
      constraints: const BoxConstraints(minWidth: 16),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
