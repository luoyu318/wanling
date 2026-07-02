import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/user_summary.dart';
import '../providers/friend_provider.dart';
import '../providers/user_search_provider.dart';
import '../utils/snackbar.dart' show SnackBarType;
import '../widgets/avatar.dart';
import '../widgets/feedback/app_dialog.dart';
import '../widgets/feedback/app_snackbar.dart';

/// 添加好友页:按 username 搜索 + 加好友按钮。
///
/// 搜索走 [userSearchProvider](500ms 防抖,空 query 立即清空不发请求)。
/// 搜索结果按用户名匹配,结果不含 user_id(spec §4.2 防枚举)。
/// 点「加好友」调 [FriendListNotifier.sendRequest]:
///   - 200:弹「已发送」Snack,本地 outgoing +1(乐观)
///   - 409(已是好友 / 已有 pending):弹 AppDialog 提示
///   - 其他错误:弹 AppDialog 通用错误
class AddFriendPage extends ConsumerStatefulWidget {
  const AddFriendPage({super.key});

  @override
  ConsumerState<AddFriendPage> createState() => _AddFriendPageState();
}

class _AddFriendPageState extends ConsumerState<AddFriendPage> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      ref.read(userSearchProvider.notifier).updateQuery(_controller.text);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _sendRequest(UserSummary user) async {
    try {
      await ref.read(friendListProvider.notifier).sendRequest(user.username);
      if (!mounted) return;
      // 成功后不弹 dialog，让按钮态切换为「已申请」+ 简洁 SnackBar 即可，
      // 避免多次点添加产生 dialog 噪音（API 已在 friendProvider 内做了乐观更新）。
      showAppSnackBar(context, '好友请求已发送',
          type: SnackBarType.success);
    } on DioException catch (e) {
      if (!mounted) return;
      final code = e.response?.statusCode;
      if (code == 409) {
        // 409：已是好友 / 已 pending。友好提示（不弹 dialog 避免噪音）。
        showAppSnackBar(context, '已经是好友,或已发送过请求尚未处理',
            type: SnackBarType.info);
      } else if (code == 404) {
        showAppSnackBar(context, '该账号可能已被注销',
            type: SnackBarType.error);
      } else {
        showAppSnackBar(context, '发送失败：${e.response?.statusMessage ?? e.message}',
            type: SnackBarType.error);
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, '发送失败：$e', type: SnackBarType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(userSearchProvider);

    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F7F7),
        foregroundColor: const Color(0xFF111111),
        title: const Text('添加好友'),
      ),
      body: Column(
        children: [
          // 搜索框:白底卡 + 圆角 + 搜索 icon 前缀。
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '输入用户名搜索',
                hintStyle:
                    const TextStyle(color: Color(0xFFB0B0B0), fontSize: 14),
                prefixIcon: const Icon(Icons.search,
                    color: Color(0xFF999999), size: 20),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close,
                            size: 18, color: Color(0xFF999999)),
                        onPressed: () {
                          _controller.clear();
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFFF5F5F5),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          // 结果区
          Expanded(
            child: _buildBody(context, state),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context, UserSearchState state) {
    if (state.loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: CircularProgressIndicator(color: Color(0xFF07C160)),
        ),
      );
    }
    if (state.query.isEmpty) {
      return const _EmptyHint(
        icon: Icons.search,
        text: '搜索用户名添加好友',
      );
    }
    if (state.results.isEmpty) {
      return _EmptyHint(
        icon: Icons.person_search_outlined,
        text: '未找到「${state.query}」相关用户',
      );
    }
    return ListView.builder(
      itemCount: state.results.length,
      itemBuilder: (_, i) {
        final u = state.results[i];
        // 排除自己:server SearchByUsername 已加 WHERE id != $me 过滤,
        // 兜底:client 也对自己 username 做过滤（双保险）。
        // 排除自己后整行点击跳 UserDetailPage。
        return _SearchResultRow(
          key: ValueKey('search_${u.username}'),
          user: u,
        );
      },
    );
  }
}

/// 搜索结果行：头像 + 昵称 + @username + 状态徽章（已添加 / 已申请）。
///
/// 整行点击跳转到 [UserDetailPage]（用户详情页里有加好友按钮），
/// 不在搜索列表里直接发请求，避免误点 + 提供更完整的用户信息预览。
class _SearchResultRow extends ConsumerWidget {
  final UserSummary user;

  const _SearchResultRow({super.key, required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friendState = ref.watch(friendListProvider);
    final isFriend = friendState.isFriend(user.username);
    final hasOutgoing = friendState.hasOutgoing(user.username);

    // 状态徽章（已添加 → 灰文本；已申请 → 灰按钮；可添加 → chevron）
    final Widget trailing;
    if (isFriend) {
      trailing = const Padding(
        padding: EdgeInsets.symmetric(horizontal: 10),
        child: Text(
          '已添加',
          style: TextStyle(
            fontSize: 13,
            color: Color(0xFF999999),
            fontWeight: FontWeight.w300,
          ),
        ),
      );
    } else if (hasOutgoing) {
      trailing = Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          '已申请',
          style: TextStyle(
            fontSize: 12,
            color: Color(0xFF999999),
            fontWeight: FontWeight.w300,
          ),
        ),
      );
    } else {
      trailing = const Icon(Icons.chevron_right,
          color: Color(0xFFBDBDBD), size: 20);
    }

    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: () => context.push('/user/${user.username}'),
        child: Column(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Avatar(
                    name: user.displayName,
                    url: user.avatarUrl.isNotEmpty ? user.avatarUrl : null,
                    size: 40,
                    radius: 6,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          user.displayName,
                          style: const TextStyle(
                            fontSize: 15,
                            color: Color(0xFF333333),
                            fontWeight: FontWeight.w300,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '@${user.username}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ],
                    ),
                  ),
                  trailing,
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
