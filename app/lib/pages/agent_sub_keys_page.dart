// 授权密钥管理页(GET /api/agents/:id/subkeys):列表含已吊销,行内吊销(二次确认→
// DELETE→重拉)。授权密钥仅 REST 可用,不能建长连接;重置主密钥会级联吊销全部子密钥。
// 模板: templates/flutter-page.dart.tmpl(const+key/loading+error UI/资源释放)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/agent_sub_key_info.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/utils/relative_time.dart';
import 'package:wanling_core/utils/snackbar.dart';
import '../widgets/feedback/app_dialog.dart';

class AgentSubKeysPage extends ConsumerStatefulWidget {
  final String agentId;

  const AgentSubKeysPage({super.key, required this.agentId}); // const + key（审计 L2/S2）

  @override
  ConsumerState<AgentSubKeysPage> createState() => _AgentSubKeysPageState();
}

class _AgentSubKeysPageState extends ConsumerState<AgentSubKeysPage> {
  late Future<List<AgentSubKeyInfo>> _future;

  @override
  void initState() {
    super.initState();
    // 副作用放 initState（审计 M7），不放 build
    _future = ref.read(apiProvider).listSubKeys(widget.agentId);
  }

  void _refresh() {
    setState(() {
      _future = ref.read(apiProvider).listSubKeys(widget.agentId);
    });
  }

  void _confirmRevoke(AgentSubKeyInfo key) {
    showAppDialog(
      context: context,
      title: '吊销「${key.name}」？',
      content: const Text(
        '吊销后该密钥不能再换新 token，已签发 token 过期前仍有效',
      ),
      confirmText: '吊销',
      onConfirm: () => _revoke(key),
    );
  }

  Future<void> _revoke(AgentSubKeyInfo key) async {
    try {
      await ref.read(apiProvider).revokeSubKey(widget.agentId, key.id);
      if (!mounted) return;
      showAppSnackBar(context, '已吊销「${key.name}」', type: SnackBarType.success);
      _refresh();
    } catch (e) {
      // fail fast 不吞异常:错误透传到 UI 反馈,由用户重试或反馈
      if (!mounted) return;
      showAppSnackBar(context, '吊销失败：$e', type: SnackBarType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('授权密钥')),
      body: FutureBuilder<List<AgentSubKeyInfo>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            // 审计 F7：加载失败不静默
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('加载失败：${snap.error}'),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _refresh, child: const Text('重试')),
                ],
              ),
            );
          }
          final keys = snap.data!;
          return ListView(
            children: [
              Container(
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F5F5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '授权密钥仅供 REST 调用，不能建立长连接；重置主密钥将同时吊销全部授权密钥',
                  style: TextStyle(fontSize: 12, color: Color(0xFF999999), height: 1.5),
                ),
              ),
              if (keys.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 120),
                  child: Center(child: Text('暂无授权密钥')),
                )
              else
                ...keys.map(_buildTile),
            ],
          );
        },
      ),
    );
  }

  Widget _buildTile(AgentSubKeyInfo key) {
    final revoked = key.isRevoked;
    const grey = Color(0xFF999999);
    return ListTile(
      title: Text(
        key.name,
        style: TextStyle(
          fontSize: 15,
          color: revoked ? grey : const Color(0xFF111111),
        ),
      ),
      subtitle: Text(
        '创建于 ${formatRelativeTime(key.createdAt)}'
        ' · 最后使用 ${key.lastUsedAt == null ? '从未使用' : formatRelativeTime(key.lastUsedAt!)}',
        style: const TextStyle(fontSize: 12, color: grey),
      ),
      // 已吊销整行置灰(名称/状态同灰阶)
      trailing: revoked
          ? const Text('已吊销', style: TextStyle(fontSize: 12, color: grey))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.circle, size: 8, color: Color(0xFF07C160)),
                const SizedBox(width: 4),
                const Text('生效中', style: TextStyle(fontSize: 12, color: grey)),
                TextButton(
                  onPressed: () => _confirmRevoke(key),
                  child: Text('吊销',
                      style: TextStyle(
                          fontSize: 13, color: Theme.of(context).colorScheme.error)),
                ),
              ],
            ),
    );
  }
}
