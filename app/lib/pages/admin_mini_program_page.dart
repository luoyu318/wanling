// 小程序审核页(admin 专属):一次拉全量,按 status 三 Tab 分组(待审/已发布/已下架)。
// 行内流转按钮(发布/下架/上架)→ showAppDialog 二次确认 → setMiniProgramStatus
// → invalidate 刷新;403 无权限兜底,其他错误可重试。
// 模板: templates/flutter-page.dart.tmpl(const+key/loading+error UI)。
import 'package:dio/dio.dart' show DioException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/admin_mini_program_info.dart';
import 'package:wanling_core/providers/admin_mini_programs_provider.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/services/api_response.dart';

import '../widgets/avatar.dart';
import '../widgets/feedback/app_dialog.dart';

/// 解包网络层错误:ApiService 拦截器把 envelope error 包成 ApiException 塞进
/// DioException.error 抛出(见 ApiService._wrapError),直接 `is ApiException`
/// 判定对真实网络路径恒 false,必须先解包再判(参照 api_service.dart 同款模式)。
ApiException? _asApiError(Object error) {
  final err = error is DioException ? error.error : error;
  return err is ApiException ? err : null;
}

class AdminMiniProgramPage extends ConsumerStatefulWidget {
  const AdminMiniProgramPage({super.key}); // const + key（审计 L2/S2）

  @override
  ConsumerState<AdminMiniProgramPage> createState() =>
      _AdminMiniProgramPageState();
}

class _AdminMiniProgramPageState extends ConsumerState<AdminMiniProgramPage> {
  static const _tabs = [
    (label: '待审', status: 'private'),
    (label: '已发布', status: 'published'),
    (label: '已下架', status: 'disabled'),
  ];

  /// 当前状态 → (按钮文案, 目标状态)。private 待发布,published 可下架,disabled 可再上架。
  static (String, String) _actionFor(String status) => switch (status) {
        'private' => ('发布', 'published'),
        'published' => ('下架', 'disabled'),
        _ => ('上架', 'published'),
      };

  @override
  Widget build(BuildContext context) {
    final baseUrl = ref.watch(apiProvider).baseUrl;
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: const Text('小程序审核'),
          bottom: TabBar(
            tabs: [for (final t in _tabs) Tab(text: t.label)],
          ),
        ),
        body: TabBarView(
          children: [
            for (final t in _tabs) _MpList(status: t.status, baseUrl: baseUrl),
          ],
        ),
      ),
    );
  }
}

class _MpList extends ConsumerWidget {
  final String status;
  final String baseUrl;

  const _MpList({required this.status, required this.baseUrl});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(adminMiniProgramsProvider);
    return RefreshIndicator(
      onRefresh: () async => ref.refresh(adminMiniProgramsProvider.future),
      child: async.when(
        // 下拉刷新/操作后 invalidate 保旧数据,静默换新,不闪 loading
        skipLoadingOnReload: true,
        skipLoadingOnRefresh: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorView(error: e),
        data: (list) {
          final items = list.where((m) => m.status == status).toList();
          if (items.isEmpty) {
            return ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 120),
                Center(child: Text('暂无小程序')),
              ],
            );
          }
          return ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            itemCount: items.length,
            itemBuilder: (ctx, i) {
              final mp = items[i];
              final (action, target) = _AdminMiniProgramPageState._actionFor(
                  mp.status);
              return ListTile(
                leading: Avatar(
                  name: mp.name,
                  url: mp.icon.isEmpty ? null : '$baseUrl${mp.icon}',
                  size: 44,
                  radius: 11,
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(mp.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(width: 6),
                    Text('v${mp.version}',
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade500)),
                  ],
                ),
                subtitle:
                    Text('${mp.ownerUsername} · ${_fmtSize(mp.size)}'),
                trailing: TextButton(
                  onPressed: () => _confirmChange(context, ref, mp, action,
                      target),
                  child: Text(action),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _confirmChange(BuildContext context, WidgetRef ref,
      AdminMiniProgramInfo mp, String action, String target) {
    showAppDialog(
      context: context,
      title: '确认$action？',
      content: Text('将把「${mp.name}」$action。'),
      confirmText: '确认',
      onConfirm: () => _applyChange(context, ref, mp, action, target),
    );
  }

  Future<void> _applyChange(BuildContext context, WidgetRef ref,
      AdminMiniProgramInfo mp, String action, String target) async {
    try {
      await ref.read(apiProvider).setMiniProgramStatus(mp.id, target);
      ref.invalidate(adminMiniProgramsProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('操作成功')));
    } catch (e) {
      // fail fast 不吞异常:错误透传到 UI 反馈,由用户重试或反馈
      // 拦截器把 ApiException 包在 DioException.error 里,先解包再分流
      final api = _asApiError(e);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(api == null
              ? '操作失败: $e'
              : api.statusCode == 403
                  ? '无权限操作'
                  : '操作失败: ${api.message}')));
    }
  }
}

class _ErrorView extends ConsumerWidget {
  final Object error;

  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 403 是权限问题,重试无意义,只提示;其他错误给重试入口
    // 拦截器把 ApiException 包在 DioException.error 里,先解包再判(见 _asApiError)
    final api = _asApiError(error);
    if (api != null && api.statusCode == 403) {
      return const Center(child: Text('无权限查看'));
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('加载失败: $error'),
          TextButton(
            onPressed: () => ref.invalidate(adminMiniProgramsProvider),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

String _fmtSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
}
