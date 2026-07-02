import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/user_summary.dart';
import '../providers/auth_provider.dart' show apiProvider;
import '../providers/friend_provider.dart';
import '../utils/snackbar.dart' show SnackBarType;
import '../widgets/avatar.dart';
import '../widgets/feedback/app_snackbar.dart';

/// 用户详情页：按 username 拉对方资料展示 + 加好友按钮。
///
/// 跟 AgentDetailPage 类似但更简化：
///   - 头像 + 昵称 + @username（无 secret_key / 无编辑入口）
///   - 三态加好友按钮（复用 AddFriendPage 同款逻辑）
///
/// 路由：`/user/:username`（按 username 查，path 参数；不暴露 user_id）。
class UserDetailPage extends ConsumerStatefulWidget {
  final String username;

  const UserDetailPage({super.key, required this.username});

  @override
  ConsumerState<UserDetailPage> createState() => _UserDetailPageState();
}

class _UserDetailPageState extends ConsumerState<UserDetailPage> {
  UserSummary? _user;
  bool _loading = true;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  Future<void> _loadUser() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(apiProvider).getUserByUsername(widget.username);
      if (!mounted) return;
      setState(() {
        _user = UserSummary.fromJson(data);
        _loading = false;
      });
    } on DioException catch (e) {
      if (!mounted) return;
      final code = e.response?.statusCode;
      setState(() {
        _loading = false;
        _error = code == 404 ? '用户不存在' : '加载失败：${e.response?.statusMessage ?? e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _sendRequest() async {
    final u = _user;
    if (u == null || _sending) return;
    setState(() => _sending = true);
    try {
      await ref.read(friendListProvider.notifier).sendRequest(u.username);
      if (!mounted) return;
      showAppSnackBar(context, '好友请求已发送', type: SnackBarType.success);
    } on DioException catch (e) {
      if (!mounted) return;
      final code = e.response?.statusCode;
      if (code == 409) {
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
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final friendState = ref.watch(friendListProvider);
    final user = _user;
    final isFriend = user != null && friendState.isFriend(user.username);
    final hasOutgoing = user != null && friendState.hasOutgoing(user.username);

    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF7F7F7),
        foregroundColor: const Color(0xFF111111),
        title: Text(user?.displayName ?? '@${widget.username}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF07C160)))
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _loadUser)
              : user == null
                  ? const _ErrorView(message: '用户不存在')
                  : ListView(
                      children: [
                        const SizedBox(height: 24),
                        // 头像 + 昵称区
                        Center(
                          child: Column(
                            children: [
                              Avatar(
                                name: user.displayName,
                                url: user.avatarUrl.isNotEmpty ? user.avatarUrl : null,
                                size: 80,
                                radius: 12,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                user.displayName,
                                style: const TextStyle(
                                  fontSize: 18,
                                  color: Color(0xFF111111),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '@${user.username}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF999999),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 32),
                        // 加好友按钮（三态）
                        if (!isFriend)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: _buildActionButton(
                              hasOutgoing: hasOutgoing,
                              sending: _sending,
                              onSend: _sendRequest,
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0F0F0),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Center(
                                child: Text(
                                  '已添加',
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: Color(0xFF999999),
                                    fontWeight: FontWeight.w300,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
    );
  }

  Widget _buildActionButton({
    required bool hasOutgoing,
    required bool sending,
    required VoidCallback onSend,
  }) {
    if (hasOutgoing) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF0F0F0),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Center(
          child: Text(
            '已申请',
            style: TextStyle(
              fontSize: 15,
              color: Color(0xFF999999),
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: sending ? null : onSend,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF07C160),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFF80D9A9),
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        child: sending
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('加好友', style: TextStyle(fontSize: 15)),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _ErrorView({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_off_outlined,
                size: 48, color: Color(0xFFB0B0B0)),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF999999), fontSize: 13),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
