import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      showAppSnackBar(context, '已向 ${user.displayName} 发送请求',
          type: SnackBarType.success);
    } on DioException catch (e) {
      if (!mounted) return;
      final code = e.response?.statusCode;
      if (code == 409) {
        // 409 Conflict:已是好友 / 已有 pending 请求
        showAppDialog(
          context: context,
          title: '无法发送',
          content: const Text('你们已经是好友,或已发送过请求尚未处理。'),
          confirmText: '知道了',
        );
      } else if (code == 404) {
        // 理论上搜索结果应可加,404 多为对方账号已被注销
        showAppDialog(
          context: context,
          title: '用户不存在',
          content: const Text('该账号可能已被注销。'),
          confirmText: '知道了',
        );
      } else {
        showAppDialog(
          context: context,
          title: '发送失败',
          content: Text('${e.response?.statusMessage ?? e.message}'),
          confirmText: '知道了',
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppDialog(
        context: context,
        title: '发送失败',
        content: Text('$e'),
        confirmText: '知道了',
      );
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
        // 排除自己:UserSummary 不含 user_id,但 server 搜索默认应排除自己,
        // 此处不强过滤(若 server 返回自己,加自己按钮按下也会 409)。
        return _SearchResultRow(
          key: ValueKey('search_${u.username}'),
          user: u,
          onAdd: () => _sendRequest(u),
        );
      },
    );
  }
}

/// 搜索结果行:头像 + 昵称 + @username + 「加好友」按钮。
class _SearchResultRow extends StatelessWidget {
  final UserSummary user;
  final VoidCallback onAdd;

  const _SearchResultRow({
    super.key,
    required this.user,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: InkWell(
        onTap: onAdd,
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
                  FilledButton(
                    onPressed: onAdd,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF07C160),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(64, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: const Text('加好友', style: TextStyle(fontSize: 13)),
                  ),
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
