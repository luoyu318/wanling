import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/pairing.dart';
import '../providers/auth_provider.dart' show apiProvider;
import '../utils/snackbar.dart';
import '../widgets/avatar.dart';
import '../widgets/feedback/app_dialog.dart';

/// 扫码后选择/新建 Agent 页。
/// 顶部 AppBar ← 返回；列表显示当前 user 名下 agent（scan 接口返回）；
/// 点击已有 agent 弹"重置密钥"确认；底部"+ 新建 Agent"弹输入框。
class PairSelectAgentPage extends ConsumerStatefulWidget {
  final String ticketId;
  const PairSelectAgentPage({super.key, required this.ticketId});

  @override
  ConsumerState<PairSelectAgentPage> createState() => _PairSelectAgentPageState();
}

class _PairSelectAgentPageState extends ConsumerState<PairSelectAgentPage> {
  late Future<PairScanResult> _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(apiProvider).pairScan(widget.ticketId);
  }

  Future<void> _refresh() async {
    setState(() {
      _future = ref.read(apiProvider).pairScan(widget.ticketId);
    });
    await _future;
  }

  void _onSelectExisting(PairAgentSummary agent) {
    showAppDialog(
      context: context,
      title: '重置密钥',
      content: Text(
        '该 Agent「${agent.name}」可能正在被其他 hermes 使用。\n'
        '继续将重置其密钥使旧连接失效，确定吗？',
      ),
      confirmText: '确定重置',
      onConfirm: () => _doComplete(agentId: agent.id),
    );
  }

  void _onCreateNew() {
    final ctrl = TextEditingController();
    showAppDialog(
      context: context,
      title: '新建 Agent',
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Agent 名称'),
      ),
      confirmText: '创建',
      onConfirm: () {
        final name = ctrl.text.trim();
        if (name.isEmpty) return;
        _doComplete(newAgentName: name);
      },
    );
  }

  Future<void> _doComplete({String? agentId, String? newAgentName}) async {
    final api = ref.read(apiProvider);
    try {
      await api.pairComplete(
        widget.ticketId,
        agentId: agentId,
        newAgentName: newAgentName,
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        '配对完成，hermes 终端将自动完成配置',
        type: SnackBarType.success,
      );
      // 配对成功后回首页（Agent 列表会在进入时刷新）
      context.go('/');
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, '配对失败：$e', type: SnackBarType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('选择要连接的 Agent')),
      body: FutureBuilder<PairScanResult>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
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
          final result = snap.data!;
          if (result.status == 'expired') {
            return const Center(child: Text('配对码已失效，请重新扫码'));
          }
          final agents = result.agents;
          return Column(
            children: [
              Expanded(
                child: agents.isEmpty
                    ? const Center(child: Text('暂无 Agent，请新建'))
                    : ListView.builder(
                        itemCount: agents.length,
                        itemBuilder: (_, i) {
                          final a = agents[i];
                          return ListTile(
                            leading: Avatar(name: a.name, url: a.avatarUrl),
                            title: Text(a.name),
                            subtitle: a.bio != null && a.bio!.isNotEmpty ? Text(a.bio!) : null,
                            onTap: () => _onSelectExisting(a),
                          );
                        },
                      ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('新建 Agent'),
                onTap: _onCreateNew,
              ),
            ],
          );
        },
      ),
    );
  }
}
