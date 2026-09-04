import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/pages/mini_program_page.dart';
import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/services/mini_program_launcher.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/widgets/mini_program_float_ball.dart';
import 'package:app/widgets/mini_program_task_view.dart';

/// 全局小程序保活层:包在 MaterialApp.builder,永远盖在 Navigator 之上。
/// 实例视图常驻 Stack(Offstage 保活),前台只切换可见性。
class MiniProgramHost extends ConsumerStatefulWidget {
  const MiniProgramHost({
    super.key,
    required this.child,
    this.instanceViewBuilder,
  });

  final Widget child;
  final Widget Function(BuildContext, MiniProgramInstance)? instanceViewBuilder;

  @override
  ConsumerState<MiniProgramHost> createState() => _MiniProgramHostState();
}

class _MiniProgramHostState extends ConsumerState<MiniProgramHost> {
  bool _showTaskView = false;

  void _minimize() {
    ref.read(miniProgramManagerProvider).minimize();
    syncLiveRouteWith(ProviderScope.containerOf(context));
  }

  void _close(String appid) {
    ref.read(miniProgramManagerProvider).close(appid);
    syncLiveRouteWith(ProviderScope.containerOf(context));
    if (ref.read(miniProgramManagerProvider).list.isEmpty) {
      // 不 setState:上一步 close 已 notifyListeners,同帧重建即按此值渲染
      _showTaskView = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = ref.watch(miniProgramManagerProvider);
    return Stack(
      children: [
        widget.child,
        // 实例视图:全部常驻,Offstage 保活(JS/游戏继续跑)。
        // Offstage 必须按 appid 键控:list 前插/淘汰会引起槽位位移,无 key 时
        // updateChildren 把新实例原位复用进旧槽,内层 key 不匹配 → 旧实例整棵
        // 子树 deactivate 重建(WebView 状态/JS 上下文全丢),keep-alive 被击穿
        for (final inst in manager.list)
          Offstage(
            key: ValueKey('mp-inst-${inst.appid}'),
            offstage: manager.foregroundAppid != inst.appid,
            child: widget.instanceViewBuilder?.call(context, inst) ??
                MiniProgramPage.embedded(
                  key: ValueKey('mp-inst-${inst.appid}'),
                  appid: inst.appid,
                  onMinimize: _minimize,
                  onClose: () => _close(inst.appid),
                ),
          ),
        // 浮球:有后台实例且无前台
        if (!manager.hasForeground && manager.list.isNotEmpty && !_showTaskView)
          MiniProgramFloatBall(
            instances: manager.list,
            onTap: () => setState(() => _showTaskView = true),
          ),
        // 卡片多任务视图。视图为全屏遮罩,展开期间盖住一切入口,外部
        // openMiniProgramWith 置前台不可达,故不在此收起 _showTaskView;
        // 若未来出现绕过遮罩的打开入口,需在置前台处同步收起本视图。
        if (_showTaskView)
          MiniProgramTaskView(
            instances: manager.list,
            onRestore: (appid) {
              ref.read(miniProgramManagerProvider).restore(appid);
              syncLiveRouteWith(ProviderScope.containerOf(context));
              setState(() => _showTaskView = false);
            },
            onClose: _close,
            onCloseView: () => setState(() => _showTaskView = false),
          ),
      ],
    );
  }
}
