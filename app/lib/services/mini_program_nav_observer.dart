// 小程序导航观察者(C2 修复):非小程序路由压栈时自动最小化前台实例。
// 背景:Host 层实例视图盖在 Navigator 之上,小程序前台时任何 context.push
// (openPage miniPrograms/agentDetail、通知点击进聊天、深链)都被 WebView 盖住,
// 零反馈(导航黑洞)。由路由观察者统一收起(微信语义「去别处=收起」),
// 覆盖全部 push 来源,无需逐调用点改造。
// 模板说明:NavigatorObserver 是框架回调型组件(无资源生命周期),
// StreamController 骨架不适用(对齐 mini_program_launcher 的豁免先例)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/services/mini_program_snapshot.dart';

/// 非小程序路由 didPush 时,若有前台实例 → 最小化 + 实例视图 Offstage,
/// 被 push 页面同帧可见(无黑洞帧)。
///
/// 壳路由识别依赖 route.settings.name:router.dart 仅给两类小程序壳路由显式
/// `name: state.matchedLocation`(go_router push 场景 pageKey 是唯一 id 而
/// 非路径,不能复用);其余路由 name 为 null,一律按普通路由收起。
class MiniProgramAutoMinimizeObserver extends NavigatorObserver {
  @override
  void didPush(Route route, Route? previousRoute) {
    super.didPush(route, previousRoute);
    final nav = navigator;
    if (nav == null) return;
    final name = route.settings.name ?? '';
    // 小程序两类壳路由不触发收起:
    // - live 壳由 launcher 压栈,与「收起」互斥
    // - 入口壳压栈时实例尚未 open(launch 页 initState 微任务才拉起),天然无前台
    // 注意 '/mini-programs'(列表页)不是壳,name 为 null → 照常收起(正确语义)
    if (name.startsWith('/mini-program-live/') ||
        name.startsWith('/mini-program/')) {
      return;
    }
    final container = ProviderScope.containerOf(nav.context);
    final manager = container.read(miniProgramManagerProvider);
    if (!manager.hasForeground) return;
    // didPush 发生在 widget build 期,直接 minimize 会同步通知 Host 重建,
    // 触发「modify a provider while the widget tree was building」;
    // 推迟到本帧绘制完成后执行(push 转场首帧内实例已收起,无可感知黑洞帧)。
    // manager 在 didPush 同步读取;container 同步捕获传给统一收起路径
    // (抓帧 + 最小化,fail-safe),回调里不再碰 ProviderScope。
    final captured = container;
    WidgetsBinding.instance.addPostFrameCallback((_) =>
        // syncRoute=false:栈顶刚被本次 push 占据,弹壳会弹错路由
        minimizeWithSnapshot(captured, syncRoute: false));
    // 不在此弹 live 壳:此刻栈顶刚被本次 push 占据,router.pop() 会弹错路由;
    // 壳保留在栈下,由壳页既有「残余壳兜底」在返回链路上自清。
  }
}
