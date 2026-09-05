// 小程序快照抓取编排(fail-safe):最小化前从 WebView 抓真实帧存入实例,
// 任务视图卡片据此显示真实页面缩略(增强;抓帧失败保留占位渐变,严禁阻断最小化)。
//
// controller 注册:WebView 归 MiniProgramPage State 私有,Host/Observer 无法
// 直达。页面 onWebViewCreated 时按 appid 注册、dispose 时注销,本模块提供
// 注册表与「抓帧 + 最小化」统一编排,Host._minimize 与 AutoMinimizeObserver
// 两条收起路径都走它。抓帧必须发生在实例视图 Offstage 之前(Hidden 后无内容)。
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/services/mini_program_launcher.dart';

/// 按 appid 注册的 WebView controller(小程序嵌入页生命周期内有效)。
final Map<String, InAppWebViewController> miniProgramControllerRegistry = {};

/// 测试用:清空注册表(模块级状态,对齐 resetLauncherForTest 先例)。
@visibleForTesting
void resetMiniProgramControllersForTest() =>
    miniProgramControllerRegistry.clear();

/// 页面注册/注销(嵌入页 onWebViewCreated / dispose 调)。
void registerMiniProgramController(String appid, InAppWebViewController c) =>
    miniProgramControllerRegistry[appid] = c;
void unregisterMiniProgramController(String appid) =>
    miniProgramControllerRegistry.remove(appid);

/// 抓帧(尽力而为):返回帧字节,任何失败(无 controller/null/异常)返回 null,
/// 调用方保留占位渐变。
Future<Uint8List?> captureSnapshot(String appid) async {
  final controller = miniProgramControllerRegistry[appid];
  if (controller == null) return null;
  try {
    return await controller.takeScreenshot();
  } catch (e) {
    debugPrint('[mini-program] 快照抓取失败(保留占位): $e');
    return null;
  }
}

/// 最小化 + 抓帧统一收起路径:先抓帧(此刻 WebView 仍前台,Offstage 未置,
/// 帧有内容),再最小化置 Offstage。收起语义(fail-safe)不变:
/// 抓帧失败不影响最小化。返回抓到的帧(测试断言用,生产忽略)。
///
/// [syncRoute]:是否同步 live 壳路由(Host 路径需要)。Observer 的 didPush
/// 路径必须传 false——此刻栈顶刚被新路由占据,pop 会弹错路由,残余壳由
/// 壳页「残余壳兜底」在返回链路上自清(原 observer 语义)。
Future<Uint8List?> minimizeWithSnapshot(
  ProviderContainer container, {
  bool syncRoute = true,
}) async {
  final manager = container.read(miniProgramManagerProvider);
  final appid = manager.foregroundAppid;
  Uint8List? frame;
  if (appid != null) {
    frame = await captureSnapshot(appid);
    if (frame != null) manager.updateSnapshot(appid, frame);
  }
  manager.minimize();
  if (syncRoute) syncLiveRouteWith(container);
  return frame;
}
