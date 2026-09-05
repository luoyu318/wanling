// 小程序卡片多任务视图:全屏遮罩上按真实屏幕宽高比缩放实例卡片
// (PageView 横滑),顶部实例 tab;点卡片恢复、上滑关闭实例,
// 点空白遮罩 / 系统返回关闭视图。由 Host 挂在根 Stack 顶层(Task 6 接线)。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/services/mini_program_manager.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'avatar.dart';

/// 卡片布局计算(纯函数,便于确定性测试):
/// 卡片 = 整屏等比缩略,宽 0.74 倍屏宽,高按真实屏幕宽高比;
/// PageView viewportFraction = (cardW + 20) / 屏宽(相邻页留 20 缝)。
({double cardW, double cardH, double viewportFraction}) taskCardLayout(
    Size screen) {
  final cardW = screen.width * 0.74;
  final cardH = cardW * screen.height / screen.width;
  return (
    cardW: cardW,
    cardH: cardH,
    viewportFraction: (cardW + 20) / screen.width,
  );
}

/// 展示名与图标已由 [resolveInstanceMeta] 解析后传入(快照空时回填注册列表)。

/// 小程序卡片多任务视图(全屏遮罩)。
class MiniProgramTaskView extends ConsumerStatefulWidget {
  const MiniProgramTaskView({
    super.key,
    required this.instances,
    required this.onRestore,
    required this.onClose,
    required this.onCloseView,
  });

  /// 保活实例列表(Host 从 manager.list 传入)。
  final List<MiniProgramInstance> instances;

  /// 点卡片 / tab → 恢复该实例到前台。
  final ValueChanged<String> onRestore;

  /// 上滑卡片 → 关闭(销毁)该实例。
  final ValueChanged<String> onClose;

  /// 点空白遮罩 / 系统返回 → 关闭任务视图本身。
  final VoidCallback onCloseView;

  @override
  ConsumerState<MiniProgramTaskView> createState() =>
      _MiniProgramTaskViewState();
}

class _MiniProgramTaskViewState extends ConsumerState<MiniProgramTaskView> {
  PageController? _pageCtrl;

  /// 恢复实例到前台,随后任务视图自身关闭(mockup 语义)。
  void _restore(String appid) {
    widget.onRestore(appid);
    widget.onCloseView();
  }

  @override
  void dispose() {
    _pageCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final layout = taskCardLayout(size);
    final instances = widget.instances;
    // 首帧按当前屏宽建 controller(屏转场少见,不做动态重建)
    _pageCtrl ??= PageController(viewportFraction: layout.viewportFraction);

    // 实例元数据回填(D):快照常为空,按 appid 查注册列表取最新 name/iconUrl
    final programs =
        ref.watch(miniProgramsProvider).valueOrNull ?? const [];
    final baseUrl = ref.watch(apiProvider).baseUrl;
    final metas = [
      for (final inst in instances) resolveInstanceMeta(inst, programs, baseUrl),
    ];

    // 挂在 Host Stack 顶层时无 Material 祖先,Text 会画黄色双下划线;
    // 根部自包透明 Material 保持组件自洽(不在 Host 侧修)
    return Material(
      type: MaterialType.transparency,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          widget.onCloseView();
        },
        child: GestureDetector(
          // 点击空白遮罩关闭(卡片内点击被子 GestureDetector 消费,不冒泡)
          behavior: HitTestBehavior.opaque,
          onTap: widget.onCloseView,
          child: Container(
            color: const Color(0xE6141418),
            child: SafeArea(
              child: Column(
                children: [
                  // 顶部实例 tab(圆角矩形图标横滑)
                  SizedBox(
                    height: 80,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: instances.length,
                      itemBuilder: (context, i) {
                        final inst = instances[i];
                        return _TabItem(
                          name: metas[i].name,
                          iconUrl: metas[i].iconUrl,
                          // 恢复后任务视图自身关闭(与点卡片同语义)
                          onTap: () => _restore(inst.appid),
                        );
                      },
                    ),
                  ),
                  // 卡片区:垂直居中
                  Expanded(
                    child: Center(
                      child: SizedBox(
                        height: layout.cardH,
                        child: PageView.builder(
                          controller: _pageCtrl,
                          itemCount: instances.length,
                          itemBuilder: (context, i) => _TaskCard(
                            key: ValueKey(
                                'mp-task-card-${instances[i].appid}'),
                            appid: instances[i].appid,
                            name: metas[i].name,
                            iconUrl: metas[i].iconUrl,
                            snapshot: instances[i].snapshot,
                            onRestore: () => _restore(instances[i].appid),
                            onClose: () =>
                                widget.onClose(instances[i].appid),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部实例 tab:圆角矩形图标 + 名字。
class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.name,
    required this.iconUrl,
    required this.onTap,
  });

  final String name;
  final String iconUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 14),
        child: Column(
          children: [
            // 与小程序列表一致的圆角矩形图标(40 / r12)
            Avatar(name: name, url: iconUrl.isEmpty ? null : iconUrl, size: 40, radius: 12),
            const SizedBox(height: 4),
            SizedBox(
              width: 56,
              child: Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 10)),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单张实例卡片:整屏等比缩略,点按恢复,上滑关闭。
/// 有快照帧时显示真实页面缩略(微信式),无帧回退占位渐变。
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    super.key,
    required this.appid,
    required this.name,
    required this.iconUrl,
    required this.snapshot,
    required this.onRestore,
    required this.onClose,
  });

  final String appid;
  final String name;
  final String iconUrl;

  /// 最小化前抓取的 WebView 真实帧,null = 回退占位渐变。
  final Uint8List? snapshot;
  final VoidCallback onRestore;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final color = Avatar.colorFor(name);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      // 上滑 = 关闭该实例(主流 IM 小程序同款交互)
      child: Dismissible(
        key: ValueKey('dismiss-$appid'),
        direction: DismissDirection.up,
        onDismissed: (_) => onClose(),
        background: Container(
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.only(bottom: 30),
          child: const Icon(Icons.delete_outline,
              color: Colors.white54, size: 32),
        ),
        child: GestureDetector(
          // 点卡片恢复;消费点击,不冒泡到空白遮罩
          onTap: onRestore,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Container(
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 24,
                      offset: const Offset(0, 10)),
                ],
              ),
              child: SizedBox(
                height: double.infinity,
                // 有帧 → 真实快照铺底(errorBuilder 兜底回退渐变);无帧 → 渐变占位
                child: snapshot == null
                    ? _placeholder(color)
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            snapshot!,
                            fit: BoxFit.cover,
                            // 解码宽度限 ~400:任务卡片视觉够用,防多实例大帧爆内存
                            cacheWidth: 400,
                            errorBuilder: (_, __, ___) => _placeholder(color),
                          ),
                          _cardOverlay(),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 占位渐变(快照缺失/解码失败兜底)。
  Widget _placeholder(Color color) => ColoredBox(
        color: color,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color, Color.lerp(color, Colors.black, 0.3)!],
            ),
          ),
          child: _cardOverlay(),
        ),
      );

  /// 卡片内容层:头部(图标+名) + 保活提示 + 操作提示(真实快照上半透明压边)。
  Widget _cardOverlay() => Column(
        children: [
          // 卡片头:图标 + App 名
          Container(
            height: 48,
            color: Colors.black.withValues(alpha: 0.18),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Avatar(
                    name: name,
                    url: iconUrl.isEmpty ? null : iconUrl,
                    size: 40,
                    radius: 12),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13)),
                ),
                const Icon(Icons.lock_outline,
                    color: Colors.white54, size: 14),
              ],
            ),
          ),
          // 保活提示(进度不丢的关键视觉)
          Expanded(
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text('后台保活中 · 进度不丢',
                    style: TextStyle(color: Colors.white, fontSize: 11)),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.only(bottom: 18),
            child: const Text('点击恢复 · 上滑关闭',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        ],
      );
}
