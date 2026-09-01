// 小程序列表页:公共库(published)+ 我的(private/disabled)两组宫格(4 列)。
// 点击项 → 容器页;长按 → 固定到底栏/取消固定、删除(仅私有);
// 公共库末位「+ 添加」与 AppBar 上传按钮同走 _upload 流程。
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
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/services/mini_program_service.dart';
import 'package:wanling_core/services/secure_storage.dart';
import 'package:wanling_core/theme/app_colors.dart';

import '../widgets/avatar.dart';
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
        baseUrl: ref.read(apiProvider).baseUrl,
        token: token,
        store: ref.read(localMessageStoreProvider).valueOrNull,
      );
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

  /// 删除主流程:远端删除 + 本地包清理 + 授权清理。
  /// 成功返 true;失败 SnackBar 反馈后返 false(调用方据此决定是否 unpin)。
  Future<bool> _deleteLocal(MiniProgramInfo mp) async {
    try {
      final token = await TokenVault.getAccessToken();
      if (token == null) throw StateError('未登录');
      final service = MiniProgramService(
        baseUrl: ref.read(apiProvider).baseUrl,
        token: token,
        store: ref.read(localMessageStoreProvider).valueOrNull,
      );
      await service.deleteRemote(mp.id);
      await service.removeLocal(mp.appid);
      await _clearMpPerms(mp.appid);
      ref.invalidate(miniProgramsProvider);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
      return false;
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

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(miniProgramsProvider);
    final baseUrl = ref.watch(apiProvider).baseUrl;
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
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(miniProgramsProvider.future),
        child: async.when(
          // 重进页面/下拉刷新时保旧数据,静默换新,不闪 loading
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载失败: $e')),
          data: (list) {
            if (list.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 120),
                  Center(child: Text('暂无小程序')),
                ],
              );
            }
            final published =
                list.where((m) => m.status == 'published').toList();
            final mine =
                list.where((m) => m.status != 'published').toList();
            return CustomScrollView(
              slivers: [
                if (published.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: _SectionHeader(title: '公共库')),
                  _grid(published, baseUrl, withAdd: true, onUpload: _upload),
                ],
                if (mine.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: _SectionHeader(title: '我的')),
                  _grid(mine, baseUrl),
                ],
                // 底部留白(手势条安全)
                const SliverToBoxAdapter(child: SizedBox(height: 24)),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 一组 4 列宫格。[withAdd] 时末位追加「+ 添加」项(触发 [onUpload])。
  Widget _grid(
    List<MiniProgramInfo> items,
    String baseUrl, {
    bool withAdd = false,
    VoidCallback? onUpload,
  }) {
    assert(!withAdd || onUpload != null, 'withAdd 需要传 onUpload');
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          childAspectRatio: 0.82,
        ),
        delegate: SliverChildBuilderDelegate(
          childCount: items.length + (withAdd ? 1 : 0),
          (ctx, i) {
            if (withAdd && i == items.length) {
              return _AddTile(onUpload: onUpload!);
            }
            final mp = items[i];
            return _MpTile(
              key: ValueKey('mp-tile-${mp.appid}'),
              mp: mp,
              iconUrl: mp.iconUrlFor(baseUrl),
              onDelete: _deleteLocal,
            );
          },
        ),
      ),
    );
  }
}

class _MpTile extends ConsumerWidget {
  final MiniProgramInfo mp;
  final String iconUrl;
  final Future<bool> Function(MiniProgramInfo mp) onDelete;

  const _MpTile({
    super.key,
    required this.mp,
    required this.iconUrl,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pinned =
        ref.watch(navOrderProvider).contains(navMpRef(mp.appid));
    final disabled = mp.status == 'disabled';
    final tile = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Avatar(
          name: mp.name,
          url: iconUrl.isEmpty ? null : iconUrl,
          size: 56,
          radius: 14,
        ),
        const SizedBox(height: 6),
        Text(
          disabled ? '${mp.name}·停用' : mp.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: disabled ? Colors.grey.shade400 : AppColors.textPrimary,
          ),
        ),
      ],
    );
    return InkWell(
      onTap: () => context.push('/mini-program/${mp.appid}'),
      onLongPress: () => _showMenu(context, ref, pinned),
      child: Opacity(
        opacity: disabled ? 0.45 : 1,
        child: tile,
      ),
    );
  }

  /// 长按底部菜单:固定切换 + 删除(仅私有) + 取消。
  void _showMenu(BuildContext context, WidgetRef ref, bool pinned) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  Icon(pinned ? Icons.push_pin_outlined : Icons.push_pin),
              title: Text(pinned ? '取消固定' : '固定到底栏'),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                final notifier = ref.read(navOrderProvider.notifier);
                final id = navMpRef(mp.appid);
                if (pinned) {
                  notifier.unpin(id);
                } else {
                  notifier.pin(id);
                }
              },
            ),
            if (mp.status == 'private')
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _confirmDelete(context, ref, pinned);
                },
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.of(sheetCtx).pop(),
            ),
          ],
        ),
      ),
    );
  }

  /// 删除不可逆(清远端包+本地包),先弹确认框;已固定项提示一并移除。
  void _confirmDelete(BuildContext context, WidgetRef ref, bool pinned) {
    showAppDialog(
      context: context,
      title: '确认删除小程序?',
      content: Text(pinned
          ? '该小程序已固定到底栏,将一并移除;本地数据同步清除,删除后无法恢复。'
          : '将删除该小程序及其本地数据,删除后无法恢复。'),
      confirmText: '删除',
      onConfirm: () async {
        // 删除成功才 unpin:失败时保留固定关系,用户重试后仍可从底栏进入。
        final ok = await onDelete(mp);
        if (ok) {
          ref.read(navOrderProvider.notifier).unpin(navMpRef(mp.appid));
        }
      },
    );
  }
}

class _AddTile extends StatelessWidget {
  final VoidCallback onUpload;

  const _AddTile({required this.onUpload});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onUpload,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.add, size: 26, color: Color(0xFFBBBBBB)),
          ),
          const SizedBox(height: 6),
          const Text('添加',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
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
