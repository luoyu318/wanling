// 小程序统一打开入口 + live 路由壳同步。
// 模板说明:templates/flutter-service.dart.tmpl 是 StreamController 资源型骨架,
// 本服务为无资源的模块级纯函数(live 壳占位是进程内布尔),骨架形状不适用。
// 所有小程序打开路径(深链/卡片/列表/底栏/宿主面板)都应经本文件,
// 保证「manager 前台状态」与「live 壳路由有无」一致:壳在栈上时系统返回键=最小化。
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/router.dart' show routerProvider;

/// live 壳路由是否已在栈上。
/// 所有进出都经本文件,模块级状态即可;测试用 [resetLauncherForTest] 复位。
bool _liveActive = false;

@visibleForTesting
void resetLauncherForTest() => _liveActive = false;

/// 统一小程序打开入口:置前台 + 保证 live 壳在栈上(系统返回键=最小化)。
void openMiniProgramWith(
  ProviderContainer container,
  String appid, {
  String name = '',
  String iconUrl = '',
}) {
  container
      .read(miniProgramManagerProvider)
      .open(appid, name: name, iconUrl: iconUrl);
  _ensureLiveRouteWith(container);
}

/// launch 页自己就是 live 壳,自报占位,避免 launcher 重复压栈。
void bindLiveRoute() => _liveActive = true;

/// Host 回调(最小化/恢复/关闭)之后同步 live 壳有无。
/// 返回是否弹出了一个壳页:壳页的返回键回调据此决定是否需要残余壳兜底自弹。
bool syncLiveRouteWith(ProviderContainer container) {
  final has = container.read(miniProgramManagerProvider).hasForeground;
  if (has && !_liveActive) {
    _ensureLiveRouteWith(container);
  } else if (!has && _liveActive) {
    _liveActive = false;
    final router = container.read(routerProvider);
    if (router.canPop()) {
      router.pop();
      return true;
    }
  }
  return false;
}

void _ensureLiveRouteWith(ProviderContainer container) {
  if (_liveActive) return;
  _liveActive = true;
  final appid = container.read(miniProgramManagerProvider).foregroundAppid;
  container
      .read(routerProvider)
      .push('/mini-program-live/$appid')
      .then((_) {}, onError: (Object _) {
    // push 失败(如路由未注册):复位壳占位,下次打开可重试,避免壳状态卡死
    _liveActive = false;
  });
}
