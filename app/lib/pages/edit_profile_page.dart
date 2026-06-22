import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'crop_avatar_page.dart';
import '../providers/auth_provider.dart';
import '../utils/snackbar.dart';
import '../widgets/avatar.dart';
import '../widgets/avatar_picker.dart';

/// 用户资料编辑页。头像即时换，昵称/简介统一保存。
class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key});

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  late final TextEditingController _nicknameCtrl;
  late final TextEditingController _bioCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(authProvider).user;
    _nicknameCtrl = TextEditingController(text: user?.nickname ?? '');
    _bioCtrl = TextEditingController(text: user?.bio ?? '');
  }

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  /// 点击头像：相册选图 → 裁剪页 → 上传 → 刷新预览。
  /// 三步式流程，每步失败/取消都静默返回，仅上传成功后提示。
  Future<void> _changeAvatar() async {
    // 1. 相册选图
    final rawBytes = await pickImageBytes(context);
    if (rawBytes == null || !mounted) return; // 用户取消

    // 2. 跳裁剪页，拿裁剪后 bytes
    final croppedBytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => CropAvatarPage(rawBytes: rawBytes),
      ),
    );
    if (croppedBytes == null || !mounted) return; // 用户取消裁剪

    // 3. 上传 + 刷新
    try {
      final api = ref.read(apiProvider);
      final fileId =
          await api.uploadBytes(croppedBytes, fileName: 'avatar.png');
      await ref
          .read(authProvider.notifier)
          .updateProfile(avatarUrl: '/api/files/$fileId');
      if (mounted) {
        showAppSnackBar(context, '头像已更新', type: SnackBarType.success);
      }
    } catch (e, st) {
      // 上传失败原因（nginx 413 / 网络断 / 服务端 500 等）打印到控制台，
      // 方便 adb logcat 定位；用户只看到通用文案。
      debugPrint('头像上传失败: $e\n$st');
      if (mounted) {
        showAppSnackBar(context, '头像上传失败，请重试', type: SnackBarType.error);
      }
    }
  }

  /// 保存昵称/简介：显式传值（含空串=清空），失败保留表单不关闭页面。
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(authProvider.notifier).updateProfile(
            nickname: _nicknameCtrl.text.trim(),
            bio: _bioCtrl.text.trim(),
          );
      if (mounted) context.pop();
    } catch (e, st) {
      debugPrint('保存资料失败: $e\n$st');
      if (mounted) {
        showAppSnackBar(context, '保存失败，请重试', type: SnackBarType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).user;

    return Scaffold(
      backgroundColor: const Color(0xFFEDEDED),
      appBar: AppBar(title: const Text('编辑资料')),
      body: ListView(
        children: [
          // 头像区：整体可点击换图
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: GestureDetector(
              onTap: _saving ? null : _changeAvatar,
              child: Column(
                children: [
                  Avatar(
                    name: user?.displayName ?? '?',
                    url: user?.avatarUrl,
                    size: 80,
                    radius: 10,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '点击更换头像',
                    style: TextStyle(color: Color(0xFF5B8BF7), fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 昵称
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('昵称',
                    style: TextStyle(color: Color(0xFF999999), fontSize: 12)),
                TextField(
                  controller: _nicknameCtrl,
                  maxLength: 64,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                    hintText: '设置后优先显示，否则使用账号名',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // 简介
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('简介',
                    style: TextStyle(color: Color(0xFF999999), fontSize: 12)),
                TextField(
                  controller: _bioCtrl,
                  maxLength: 200,
                  maxLines: 3,
                  minLines: 1,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    counterText: '',
                    hintText: '介绍一下自己',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // 保存按钮
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}
