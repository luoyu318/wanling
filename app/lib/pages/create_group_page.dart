import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/conversation_provider.dart';
import '../utils/snackbar.dart' show SnackBarType;
import '../widgets/feedback/app_dialog.dart';
import '../widgets/feedback/app_snackbar.dart';

/// 新建群聊页。
///
/// 本期 placeholder:不依赖 friendListProvider(Task 4.1 范围,尚未实现)。
/// 用户手动按行输入 username(每行一个),创建时把每行 trim 为 username,
/// 调 createConversation(type=group_user, member_ids 用 username 数组)。
///
/// Task 4.1 启用好友系统后,本页改为:
///   - 拉好友列表(friendListProvider.load)
///   - CheckboxListTile 多选好友
///   - 创建时用选中的 user id 调 createGroup
///
/// 注意:本期 username 输入仅用于测试。生产场景必须用好友 id,且 server
/// 会校验 type=group_user 时创建者与成员都是好友(否则返 403)。
class CreateGroupPage extends ConsumerStatefulWidget {
  const CreateGroupPage({super.key});

  @override
  ConsumerState<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends ConsumerState<CreateGroupPage> {
  final _titleCtrl = TextEditingController();
  final _membersCtrl = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _membersCtrl.dispose();
    super.dispose();
  }

  /// 解析 username 输入:每行一个,trim 后去空行去重。
  List<String> get _parsedMemberIds {
    return _membersCtrl.text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toSet()
        .toList();
  }

  bool get _canCreate {
    return _titleCtrl.text.trim().isNotEmpty &&
        _parsedMemberIds.length >= 2 &&
        !_creating;
  }

  Future<void> _create() async {
    if (!_canCreate) return;
    setState(() => _creating = true);
    try {
      final memberIds = _parsedMemberIds;
      await ref.read(conversationProvider.notifier).createGroup(
            memberIds: memberIds,
            title: _titleCtrl.text.trim(),
          );
      if (!mounted) return;
      // 创建后回首页让消息列表刷新看到新会话。
      // 注:ChatPage 当前必传 agentId(为 1-1 agent 模型设计),group 场景
      // agentId 不适用。group ChatPage 的接入由 Batch 3 后续 task 处理,
      // 本 task 范围只把创建链路打通。
      showAppSnackBar(context, '群聊已创建', type: SnackBarType.success);
      context.go('/');
    } catch (e) {
      if (mounted) {
        showAppDialog(
          context: context,
          title: '创建失败',
          content: Text('$e'),
          confirmText: '知道了',
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final memberCount = _parsedMemberIds.length;

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
      body: ListView(
        children: [
          // 群名输入
          Container(
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
          ),
          // 成员输入(placeholder:按行输 username)
          Container(
            color: Colors.white,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text(
                      '群成员',
                      style: TextStyle(
                          fontSize: 15, color: Color(0xFF333333)),
                    ),
                    const Spacer(),
                    Text(
                      '$memberCount 人',
                      style: const TextStyle(
                          color: Color(0xFF999999), fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _membersCtrl,
                  maxLines: 6,
                  minLines: 4,
                  decoration: const InputDecoration(
                    hintText: '每行输入一个用户名(至少 2 人)\n好友系统启用后将支持多选',
                    hintStyle: TextStyle(
                        color: Color(0xFFB0B0B0), fontSize: 13, height: 1.5),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(12),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ),
          ),
          // 提示卡
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFFACC15), width: 0.5),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: Color(0xFFCA8A04)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '当前为 placeholder:好友系统(Task 4.1)上线后将改为多选好友列表。',
                    style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFFCA8A04),
                        height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
