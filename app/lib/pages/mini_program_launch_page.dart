// 小程序入口路由壳 + live 返回键壳。
// launch 页本身无 UI(WebView 由宿主层按 manager 前台渲染),职责 =
// 拉起保活实例 + 系统返回键转最小化;live 壳页职责仅为拦截系统返回键。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/services/mini_program_launcher.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';

/// 系统返回键拦截壳:返回 = 最小化(前台清空 + live 路由同步)。
class _MinimizeOnPop extends StatelessWidget {
  const _MinimizeOnPop();

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final container = ProviderScope.containerOf(context);
        container.read(miniProgramManagerProvider).minimize();
        syncLiveRouteWith(container);
      },
      child: const SizedBox.shrink(),
    );
  }
}

/// 深链/入口路由壳:页面本身无 UI(宿主层覆盖),
/// 职责 = 拉起保活实例 + 系统返回键转最小化。
class MiniProgramLaunchPage extends ConsumerStatefulWidget {
  const MiniProgramLaunchPage({
    super.key,
    required this.appid,
    this.conversationId,
    this.launchParams,
  });

  final String appid;

  /// 从聊天卡片打开时的来源会话,透传给小程序入口 URL query。
  final String? conversationId;

  /// 卡片跳转携带的 launch 参数,透传给小程序入口 URL query。
  final String? launchParams;

  @override
  ConsumerState<MiniProgramLaunchPage> createState() =>
      _MiniProgramLaunchPageState();
}

class _MiniProgramLaunchPageState extends ConsumerState<MiniProgramLaunchPage> {
  @override
  void initState() {
    super.initState();
    bindLiveRoute();
    Future.microtask(() {
      if (!mounted) return;
      // 列表已加载则顺带带元信息(浮球/多任务显示),未加载仅 appid,面板侧后续补
      final info = ref
          .read(miniProgramsProvider)
          .valueOrNull
          ?.where((e) => e.appid == widget.appid)
          .firstOrNull;
      final container = ProviderScope.containerOf(context);
      openMiniProgramWith(
        container,
        widget.appid,
        name: info?.name ?? '',
        iconUrl: info == null
            ? ''
            // 列表已加载说明 api 已就绪,读 baseUrl 拼 icon 完整 URL
            : info.iconUrlFor(container.read(apiProvider).baseUrl),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return const _MinimizeOnPop();
  }
}

/// live 路由壳:页面本身无 UI(WebView 由宿主层渲染),
/// 职责仅为拦截系统返回键(返回 = 最小化)。
class MiniProgramLiveShellPage extends StatelessWidget {
  const MiniProgramLiveShellPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _MinimizeOnPop();
  }
}
