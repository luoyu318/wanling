import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/user_summary.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/friend_provider.dart';
import 'package:wanling_core/utils/snackbar.dart' show SnackBarType;
import '../widgets/avatar.dart';
import '../widgets/feedback/app_dialog.dart';
import 'package:wanling_core/widgets/feedback/app_snackbar.dart';

/// 新建群聊页(从好友列表多选,创建 type=group_user 会话)。
///
/// 流程:
///   1. 群名输入(必填)
///   2. 好友列表多选(CheckboxListTile,至少 2 人)
///   3. 点「创建」调 conversationProvider.createGroup(memberUsernames)
///   4. 成功后 pushReplacement 到新群 ChatPage
///
/// 数据源:friendListProvider.friends(UserSummary 不含 user_id,
/// spec §4.2 防枚举,server 端 username 反查)。
class CreateGroupPage extends ConsumerStatefulWidget {
  const CreateGroupPage({super.key});

  @override
  ConsumerState<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends ConsumerState<CreateGroupPage> {
  final _titleCtrl = TextEditingController();
  // 选中态用 username 集合(UserSummary 不含 user_id,username 是稳定主键)
  final Set<String> _selectedUsernames = {};
  bool _creating = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    super.dispose();
  }

  bool get _canCreate {
    return _titleCtrl.text.trim().isNotEmpty &&
        _selectedUsernames.length >= 2 &&
        !_creating;
  }

  void _toggle(String username) {
    setState(() {
      if (_selectedUsernames.contains(username)) {
        _selectedUsernames.remove(username);
      } else {
        _selectedUsernames.add(username);
      }
    });
  }

  Future<void> _create() async {
    if (!_canCreate) return;
    setState(() => _creating = true);
    try {
      final convId = await ref.read(conversationProvider.notifier).createGroup(
            memberUsernames: _selectedUsernames.toList(),
            title: _titleCtrl.text.trim(),
          );
      if (!mounted) return;
      showAppSnackBar(context, '群聊已创建', type: SnackBarType.success);
      // 创建成功跳转到新群 ChatPage(pushReplacement 避免返回栈回到本创建页)
      context.pushReplacement('/chat/$convId');
    } catch (e) {
      if (mounted) {
        unawaited(showAppDialog(
          context: context,
          title: '创建失败',
          content: Text('$e'),
          confirmText: '知道了',
        ));
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final friendState = ref.watch(friendListProvider);
    final friends = friendState.friends;

    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F7F7),
        title: const Text('发起群聊'),
        actions: [
          TextButton(
            onPressed: _canCreate ? _create : null,
            child: Text(
              _creating ? '创建中...' : '创建',
              style: TextStyle(
                color: _canCreate
                    ? const Color(0xFF07C160)
                    : const Color(0xFFB0B0B0),
                fontSize: 15,
              ),
            ),
          ),
        ],
      ),
      body: friends.isEmpty
          ? _buildEmpty(context)
          : ListView(
              children: [
                _buildTitleInput(),
                _buildSelectedCountHeader(friends.length),
                ...friends.map(_buildFriendRow),
              ],
            ),
    );
  }

  Widget _buildTitleInput() {
    return Container(
      color: Colors.white,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: _titleCtrl,
        decoration: const InputDecoration(
          labelText: '群名称',
          hintText: '给群聊起个名字',
          border: InputBorder.none,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildSelectedCountHeader(int total) {
    return Container(
      color: const Color(0xFFF7F7F7),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Text(
            '群成员',
            style: TextStyle(fontSize: 13, color: Color(0xFF999999)),
          ),
          const SizedBox(width: 8),
          Text(
            '已选 ${_selectedUsernames.length} / $total',
            style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
          ),
        ],
      ),
    );
  }

  Widget _buildFriendRow(UserSummary friend) {
    final selected = _selectedUsernames.contains(friend.username);
    // 用 Material(color:) 而非 ColoredBox / Container(color:):
    // CheckboxListTile 的 ink splash 需要最近 Material 祖先,ColoredBox 会拦截。
    return Material(
      color: Colors.white,
      child: CheckboxListTile(
        value: selected,
        onChanged: (_) => _toggle(friend.username),
        activeColor: const Color(0xFF07C160),
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        secondary: Avatar(
          // Avatar 实际签名是 name/url,不是 username/nickname/avatarUrl
          name: friend.displayName,
          url: friend.avatarUrl,
          size: 40,
        ),
        title: Text(
          friend.displayName,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w400),
        ),
        // nickname 跟 username 不同时显示 @username(辅助识别)
        subtitle: friend.nickname.isNotEmpty && friend.nickname != friend.username
            ? Text(
                '@${friend.username}',
                style: const TextStyle(fontSize: 12, color: Color(0xFF999999)),
              )
            : null,
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.people_outline, size: 56, color: Color(0xFFB0B0B0)),
          const SizedBox(height: 12),
          const Text(
            '还没有好友',
            style: TextStyle(fontSize: 14, color: Color(0xFF999999)),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => context.push('/friends/add'),
            child: const Text(
              '去添加好友',
              style: TextStyle(color: Color(0xFF07C160), fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
