// 小程序列表页:公共库(published)+ 我上传的(private/disabled)两个分组。
// 点击条目 → 容器页(容器内部处理安装/更新)。
// 上传按钮 → file_picker 选 zip → 上传建私有 → 刷新列表。
// 模板: templates/flutter-page.dart.tmpl(const+key/loading+error UI)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/local_message_store_provider.dart'
    show localMessageStoreProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/mini_program_service.dart';
import 'package:wanling_core/services/secure_storage.dart';
import 'package:wanling_core/theme/app_colors.dart';

import '../widgets/feedback/app_dialog.dart';

class MiniProgramListPage extends ConsumerStatefulWidget {
  const MiniProgramListPage({super.key});

  @override
  ConsumerState<MiniProgramListPage> createState() =>
      _MiniProgramListPageState();
}

class _MiniProgramListPageState extends ConsumerState<MiniProgramListPage> {
  bool _uploading = false;

  Future<void> _upload() async {
    if (_uploading) return;
    setState(() => _uploading = true);
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      final path = picked?.files.single.path;
      if (path == null) return;
      final token = await TokenVault.getAccessToken();
      if (token == null) throw StateError('未登录');
      final service = MiniProgramService(
          baseUrl: ref.read(apiProvider).baseUrl, token: token);
      await service.uploadPackage(path);
      ref.invalidate(miniProgramsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('上传失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _open(MiniProgramInfo mp) {
    context.push('/mini-program/${mp.appid}');
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(miniProgramsProvider);
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('小程序'),
        actions: [
          IconButton(
            onPressed: _uploading ? null : _upload,
            icon: _uploading
                ? const SizedBox(
                    width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.upload_file),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
        data: (list) {
          if (list.isEmpty) {
            return const Center(child: Text('暂无小程序'));
          }
          final published =
              list.where((m) => m.status == 'published').toList();
          final mine =
              list.where((m) => m.status != 'published').toList();
          return ListView(
            children: [
              if (published.isNotEmpty) ...[
                const _SectionHeader(title: '公共库'),
                ...published.map(_tile),
              ],
              if (mine.isNotEmpty) ...[
                const _SectionHeader(title: '我的'),
                ...mine.map(_tile),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _tile(MiniProgramInfo mp) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: AppColors.accentGreen.withValues(alpha: .12),
        child: Text(mp.name.isNotEmpty ? mp.name.characters.first : '?'),
      ),
      title: Text(mp.name),
      subtitle: Text('v${mp.version} · ${mp.status == 'published' ? '公共' : mp.status == 'private' ? '私有' : '已停用'}'),
      onTap: () => _open(mp),
      trailing: mp.status == 'private'
          ? IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmDelete(mp),
            )
          : null,
    );
  }

  /// 删除不可逆(清远端包+本地包),先弹确认框;取消不执行。
  void _confirmDelete(MiniProgramInfo mp) {
    showAppDialog(
      context: context,
      title: '确认删除小程序?',
      content: const Text('将删除该小程序及其本地数据,删除后无法恢复。'),
      confirmText: '删除',
      onConfirm: () async {
        await _deleteLocal(mp);
      },
    );
  }

  Future<void> _deleteLocal(MiniProgramInfo mp) async {
    // 私有小程序:server 删除 + 本地包清理;仅清本地(未装直接成功)。
    try {
      final token = await TokenVault.getAccessToken();
      if (token == null) throw StateError('未登录');
      final service = MiniProgramService(
          baseUrl: ref.read(apiProvider).baseUrl, token: token);
      await service.deleteRemote(mp.id);
      await service.removeLocal(mp.appid);
      await _clearMpPerms(mp.appid);
      ref.invalidate(miniProgramsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
  }

  /// 卸载即撤销授权:清 KVS mp_perm(delete 语义)。
  /// 失败不阻断删除主流程,仅记日志(主数据已删,残留授权无对应小程序)。
  Future<void> _clearMpPerms(String appid) async {
    try {
      final uid = await TokenVault.getUserId() ?? '';
      final store = ref.read(localMessageStoreProvider).valueOrNull;
      await store?.deleteMpPerms(uid, appid);
    } catch (e) {
      debugPrint('[mini-program] 清理授权失败: $e');
    }
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(title,
            style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
                fontWeight: FontWeight.w600)),
      );
}