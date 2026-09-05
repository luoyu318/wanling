import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/pages/mini_program_page.dart';
import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/services/mini_program_launcher.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/widgets/mini_program_float_ball.dart';
import 'package:app/widgets/mini_program_overlay.dart';
import 'package:app/widgets/mini_program_task_view.dart';
import 'package:wanling_core/providers/auth_provider.dart';

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

  /// manager 强引用(initState 捕获,dispose 移除监听用;dispose 内禁 ref)
  late final MiniProgramManager _manager;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(miniProgramManagerProvider);
    // 嵌入弹层生命周期:前台实例变化(最小化/切实例/关闭/登出清空)→
    // 批量关闭弹层,防 barrier 悬浮在非小程序页面上拦死宿主导航
    _manager.addListener(_dismissOverlaysOnForegroundChange);
    // 登出/切账号联动(I1):认证态从有到无(手动登出/401 踢出/切换账号的
    // logout 段都收敛到 authProvider 状态流转)→ 清空保活实例。
    // 放 app 侧 Host 消费:core 不依赖 app,不能在 core 里调 app 的 manager。
    ref.listenManual(authProvider, (prev, next) {
      // listenManual 的 previous 可为 null(首次注册前无前值):null 视为未登录
      if ((prev?.isAuthenticated ?? false) && !next.isAuthenticated) {
        ref.read(miniProgramManagerProvider).closeAll();
        // 任务视图/浮球随实例清空自然消失;视图展开标志需同步复位,
        // 防下个账号登录后直接悬在空任务视图上
        if (_showTaskView) setState(() => _showTaskView = false);
      }
    });
  }

  void _dismissOverlaysOnForegroundChange() {
    dismissMiniProgramOverlaysOnForegroundChange(_manager.foregroundAppid);
  }

  @override
  void dispose() {
    _manager.removeListener(_dismissOverlaysOnForegroundChange);
    super.dispose();
  }

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
        // Offstage 必须按 appid+openedAt 键控:appid 维度防 list 前插/淘汰的
        // 槽位位移原位复用(无 key 时 updateChildren 把新实例原位复用进旧槽,
        // 整棵子树重建,keep-alive 被击穿);openedAt 维度区分「同 appid 销毁
        // 重建」的新实例(I2 参数变化重建 → WebView 整棵换新带新参数)
        for (final inst in manager.list)
          Offstage(
            key: ValueKey(
                'mp-inst-${inst.appid}-${inst.openedAt.microsecondsSinceEpoch}'),
            offstage: manager.foregroundAppid != inst.appid,
            child: widget.instanceViewBuilder?.call(context, inst) ??
                MiniProgramPage.embedded(
                  key: ValueKey('mp-inst-${inst.appid}'),
                  appid: inst.appid,
                  conversationId: inst.conversationId,
                  launchParams: inst.launchParams,
                  onMinimize: _minimize,
                  onClose: () => _close(inst.appid),
                ),
          ),
        // 嵌入模式弹层宿主(C1):embedded 页 context 向上无 Navigator,
        // 弹层(dialog/sheet)统一经此 Overlay 呈现,层级在实例视图之上
        const MiniProgramOverlayHost(),
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
