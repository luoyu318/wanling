// 小程序卡片多任务视图(澎湃 OS 任务视图样式):毛玻璃背景(BackdropFilter)
// 上的横向队列卡组——堆叠态前台卡在基准位、后卡左缘贴屏幕左缘(微错开露层),
// 右滑跟手展开(统一插值,行程右大左小、连续无阈值)/ 左滑跟手折叠(松手停留),
// 点卡片打开对应实例,上滑关闭单实例;底部 X 清空全部任务;
// 点空白遮罩 / 系统返回关闭视图。由 Host 挂在根 Stack 顶层。
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/services/mini_program_manager.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'avatar.dart';

/// 卡片尺寸计算(纯函数,便于确定性测试):宽 0.56 倍屏宽,
/// 高整屏等比(手机屏形态,快照 contain 完整展示 + 模糊底层兜边)。
({double cardW, double cardH}) taskCardLayout(Size screen) {
  final cardW = screen.width * 0.56;
  return (cardW: cardW, cardH: cardW * screen.height / screen.width);
}

/// 展示名与图标已由 [resolveInstanceMeta] 解析后传入(快照空时回填注册列表)。

/// 小程序卡片多任务视图(全屏毛玻璃遮罩 + 堆叠卡组)。
class MiniProgramTaskView extends ConsumerStatefulWidget {
  const MiniProgramTaskView({
    super.key,
    required this.instances,
    required this.onRestore,
    required this.onClose,
    required this.onCloseView,
    required this.onCloseAll,
  });

  /// 保活实例列表(Host 从 manager.list 传入,index 0 = 前台卡)。
  final List<MiniProgramInstance> instances;

  /// 点卡片 → 恢复该实例到前台。
  final ValueChanged<String> onRestore;

  /// 上滑卡片 → 关闭(销毁)该实例。
  final ValueChanged<String> onClose;

  /// 点空白遮罩 / 系统返回 → 关闭任务视图本身。
  final VoidCallback onCloseView;

  /// 底部 X → 清空全部实例(closeAll),视图随 [onCloseView] 收起。
  final VoidCallback onCloseAll;

  @override
  ConsumerState<MiniProgramTaskView> createState() =>
      _MiniProgramTaskViewState();
}

class _MiniProgramTaskViewState extends ConsumerState<MiniProgramTaskView>
    with SingleTickerProviderStateMixin {
  /// 展开进度 0(堆叠)~1(全展开):右滑跟手增 / 左滑跟手减;
  /// 松手带速度 → 惯性匀减速滑行(滚动列表手感),无速度 → 原地停留。
  /// 用 AnimationController 而非 setState:每帧只重建卡组,不重跑整视图。
  late final AnimationController _fanCtrl;

  @override
  void initState() {
    super.initState();
    _fanCtrl = AnimationController(vsync: this);
  }

  @override
  void dispose() {
    _fanCtrl.dispose();
    super.dispose();
  }

  /// 堆叠态后卡相邻错开量(px):后卡全部贴屏幕左缘,微错开留层次
  /// (参考图 1 最左侧露出的窄条)。
  static const double _stackStagger = 12;

  /// 堆叠态近大远小:每深一层缩放比例(5%)与下限。
  static const double _stackShrink = 0.05;
  static const double _stackShrinkFloor = 0.85;

  /// 队列基准左缘(×屏宽):堆叠态前台卡位 = 拖到底最老卡位。
  /// 二者共用 → 任意 fan 下屏上恒留至少一个可见视图(最老卡)。
  static const double _baseLeftFactor = 0.16;

  /// 全展开相邻卡左缘差(×卡宽):参考图实测 ≈0.47 屏宽 / 卡宽 0.56 ≈ 0.70,
  /// 相邻卡重叠 ≈0.3 卡宽——前台卡左缘始终压着次卡右缘(参考图 2/5)。
  static const double _stepFactor = 0.70;

  /// 卡框高度:优先按快照真实宽高比(w/h)等比缩放(瘦长,消除快照与
  /// 整屏比例差导致的 contain 上下黑边),无快照/比例回退整屏等比。
  double _cardHeightFor(Size screen, double cardW, MiniProgramInstance inst) {
    if (inst.snapshot == null || inst.snapshotAspect == null) {
      return cardW * screen.height / screen.width;
    }
    // 钳制可用高度(留标题+边距),极端瘦长比例不撑爆视口
    return (cardW / inst.snapshotAspect!).clamp(0.0, screen.height * 0.85);
  }

  /// 全程拖动距离:随任务数增长(队列越长拉开越久),钳制在 0.35~0.65 屏宽。
  double _fanFullDx(Size size, int n, double cardW) {
    if (n <= 1) return 0;
    return ((n - 1) * cardW * _stepFactor * 0.5).clamp(
      size.width * 0.35,
      size.width * 0.65,
    );
  }

  /// 松手惯性:速度换算为展开进度速度(fan/s),匀减速滑行;
  /// 速度极小则原地停留(松手停留语义)。
  void _onDragEnd(DragEndDetails d, Size size, int n, double cardW) {
    final v = d.velocity.pixelsPerSecond.dx / _fanFullDx(size, n, cardW);
    if (v.abs() < 0.1) return;
    _fanCtrl.animateWith(_FanInertia(start: _fanCtrl.value, velocity: v));
  }

  /// 恢复实例到前台,随后任务视图自身关闭。
  void _restore(String appid) {
    widget.onRestore(appid);
    widget.onCloseView();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final layout = taskCardLayout(size);
    final instances = widget.instances;

    // 实例元数据回填:快照常为空,按 appid 查注册列表取最新 name/iconUrl
    final programs = ref.watch(miniProgramsProvider).valueOrNull ?? const [];
    final baseUrl = ref.watch(apiProvider).baseUrl;
    final metas = [
      for (final inst in instances)
        resolveInstanceMeta(inst, programs, baseUrl),
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
          // 点击空白遮罩关闭(卡片/按钮点击被子 GestureDetector 消费,不冒泡)
          behavior: HitTestBehavior.opaque,
          onTap: widget.onCloseView,
          child: ClipRect(
            // 毛玻璃:模糊下层内容 + 半透明压暗(纯色遮罩太死板)
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                color: const Color(0x99141418),
                child: SafeArea(
                  // 水平拖拽挂全屏层(translucent):卡随 _fan 平移会越出卡组
                  // Stack 的命中边界,deferToChild 会让越出部分拖不动。
                  // 卡组全屏垂直居中;X 悬浮底部(不挤占居中空间)。
                  // RepaintBoundary 隔离卡组逐帧重绘,避免连累毛玻璃重模糊。
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: (_) => _fanCtrl.stop(),
                    onHorizontalDragUpdate: (d) => _fanCtrl.value =
                        (_fanCtrl.value +
                                d.delta.dx /
                                    _fanFullDx(
                                      size,
                                      instances.length,
                                      layout.cardW,
                                    ))
                            .clamp(0.0, 1.0),
                    onHorizontalDragEnd: (d) =>
                        _onDragEnd(d, size, instances.length, layout.cardW),
                    child: Stack(
                      children: [
                        RepaintBoundary(
                          child: Center(
                            child: _buildDeck(size, layout, instances, metas),
                          ),
                        ),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: _closeAllButton(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 底部中央 X(澎湃 OS 同款):清空全部小程序任务,视图随 onCloseView 收起。
  Widget _closeAllButton() => GestureDetector(
    onTap: () {
      widget.onCloseAll();
      widget.onCloseView();
    },
    child: Container(
      width: 56,
      height: 56,
      decoration: const BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: const Icon(Icons.close, color: Color(0xFF141418), size: 28),
    ),
  );

  /// 堆叠卡组(澎湃 OS 队列模型):
  /// 卡片是一条横向队列,堆叠位:前台卡在基准位 base,后卡左缘贴屏幕
  /// 左缘(相邻 12px 微错开露层)→ 前台卡右侧留出 ~base 宽的露出条;
  /// 展开位:最老卡(i=n-1)回到基准位,向新卡方向依次 +step 右移,
  /// 最新卡滑向右屏外。
  /// 后层卡(深 index)先画,前台卡(index 0)盖顶。
  /// AnimatedBuilder 只重建卡组,拖拽手势由上层全屏 GestureDetector 驱动。
  /// 卡 i 左缘的 Transform 偏移(相对 Stack 居中位):
  /// 堆叠位(前台 base / 后卡贴左缘微错开)与展开位(base+(n-1-i)*step)
  /// 按统一 [fan] 插值(参考图 2-5:任意时刻相邻卡左缘差恒定,紧密衔接)。
  /// 位移右大左小来自行程差:前台行程 ≈ base+(n-1)*step,越老越小。
  /// 纯函数,便于确定性测试。
  double _cardTranslateDx({
    required double screenW,
    required double cardW,
    required int n,
    required int i,
    required double fan,
  }) {
    final step = cardW * _stepFactor;
    final base = screenW * _baseLeftFactor;
    final center = (screenW - cardW) / 2;
    final stackedLeft = i == 0 ? base : -(i - 1) * _stackStagger;
    final expandedLeft = base + (n - 1 - i) * step;
    return stackedLeft + (expandedLeft - stackedLeft) * fan - center;
  }

  /// 卡 i 缩放(近大远小层次感):堆叠态每深一层缩 5%(下限 0.85),
  /// 展开过程回到 1(参考图 2-5 展开态各卡等大)。纯函数。
  double _cardScale(int i, double fan) {
    if (i == 0) return 1.0;
    final stacked = (1 - i * _stackShrink).clamp(_stackShrinkFloor, 1.0);
    return stacked + (1.0 - stacked) * fan;
  }

  Widget _buildDeck(
    Size size,
    ({double cardW, double cardH}) layout,
    List<MiniProgramInstance> instances,
    List<({String name, String iconUrl})> metas,
  ) {
    final n = instances.length;
    if (n == 0) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _fanCtrl,
      builder: (context, _) {
        final fan = _fanCtrl.value;
        return Stack(
          alignment: Alignment.center,
          children: [
            for (var i = n - 1; i >= 0; i--)
              Transform.translate(
                key: ValueKey('mp-deck-${instances[i].appid}'),
                offset: Offset(
                  _cardTranslateDx(
                    screenW: size.width,
                    cardW: layout.cardW,
                    n: n,
                    i: i,
                    fan: fan,
                  ),
                  0,
                ),
                // 近大远小:缩放锚定卡左缘中点(左缘位置不动,贴边保持),
                // 上下对称内缩 → 堆叠态层次感(参考图 1)
                child: Transform.scale(
                  scale: _cardScale(i, fan),
                  alignment: Alignment.centerLeft,
                  child: _TaskCard(
                    key: ValueKey('mp-task-card-${instances[i].appid}'),
                    appid: instances[i].appid,
                    name: metas[i].name,
                    iconUrl: metas[i].iconUrl,
                    snapshot: instances[i].snapshot,
                    cardW: layout.cardW,
                    cardH: _cardHeightFor(size, layout.cardW, instances[i]),
                    // 标题随卡移动:波前(fan*n)从新卡往老卡扫,
                    // 扫过的卡名称显现、icon 提前一级显现(icon 恒先于名称);
                    // 前台卡恒显;拖到底(fan=1)全队可见(参考图 5)
                    iconOpacity: i == 0
                        ? 1.0
                        : (fan * n - i + 1).clamp(0.0, 1.0),
                    nameOpacity: i == 0 ? 1.0 : (fan * n - i).clamp(0.0, 1.0),
                    onRestore: () => _restore(instances[i].appid),
                    onClose: () => widget.onClose(instances[i].appid),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 单张实例卡片:标题行(icon+名,卡片上方,随卡移动)+ 快照主体。
/// 点按恢复,上滑关闭;快照 contain 完整展示,模糊底层兜边。
class _TaskCard extends StatelessWidget {
  const _TaskCard({
    super.key,
    required this.appid,
    required this.name,
    required this.iconUrl,
    required this.snapshot,
    required this.cardW,
    required this.cardH,
    required this.iconOpacity,
    required this.nameOpacity,
    required this.onRestore,
    required this.onClose,
  });

  final String appid;
  final String name;
  final String iconUrl;

  /// 最小化前抓取的 WebView 真实帧,null = 回退占位渐变。
  final Uint8List? snapshot;
  final double cardW;
  final double cardH;

  /// 标题行透明度:icon 恒保留(卡被推即显),名称推满一级间距才显。
  final double iconOpacity;
  final double nameOpacity;
  final VoidCallback onRestore;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final color = Avatar.colorFor(name);
    return SizedBox(
      width: cardW,
      // Dismissible 包「标题+卡片」整体:上滑时标题随卡片一起移动,
      // 删除阈值降到 0.35(卡片高,默认 0.75 要拖大半屏才触发);无 background
      child: Dismissible(
        key: ValueKey('dismiss-$appid'),
        direction: DismissDirection.up,
        dismissThresholds: const {DismissDirection.up: 0.35},
        onDismissed: (_) => onClose(),
        child: GestureDetector(
          // 点标题或卡片任意处恢复;消费点击,不冒泡到空白遮罩
          onTap: onRestore,
          behavior: HitTestBehavior.opaque,
          child: Column(
            // min:约束为 loose 时 Column 默认 max 会吃满全高,导致卡组贴顶
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题行(icon+名)在卡片上方(多任务样式),无锁;
              // icon 恒保留,名称按解锁进度渐显(参考澎湃 OS 实测图)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Opacity(
                      opacity: iconOpacity,
                      child: Avatar(
                        name: name,
                        url: iconUrl.isEmpty ? null : iconUrl,
                        size: 22,
                        radius: 7,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Opacity(
                        opacity: nameOpacity,
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                key: ValueKey('mp-card-body-$appid'),
                height: cardH,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    decoration: BoxDecoration(
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 24,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    // 有帧 → 双层快照:底层同帧 cover 放大 + 模糊压暗兜底
                    // (比例极端偏差时的视觉安全网),顶层 contain 完整展示;
                    // 无帧/解码失败 → 渐变占位
                    child: snapshot == null
                        ? _placeholder(color)
                        : Stack(
                            fit: StackFit.expand,
                            children: [
                              ImageFiltered(
                                imageFilter: ImageFilter.blur(
                                  sigmaX: 24,
                                  sigmaY: 24,
                                ),
                                // 小图解码即可(反正要糊掉),省内存
                                child: Image.memory(
                                  snapshot!,
                                  fit: BoxFit.cover,
                                  cacheWidth: 80,
                                ),
                              ),
                              const ColoredBox(color: Color(0x66141418)),
                              Image.memory(
                                snapshot!,
                                fit: BoxFit.contain,
                                // 解码宽度限 ~400:任务卡片视觉够用,防多实例大帧爆内存
                                cacheWidth: 400,
                                errorBuilder: (_, _, _) => _placeholder(color),
                              ),
                            ],
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 占位渐变(快照缺失/解码失败兜底)。
  Widget _placeholder(Color color) => DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color, Color.lerp(color, Colors.black, 0.3)!],
      ),
    ),
  );
}

/// 展开惯性模拟:匀减速滑行(滚动列表 ClampingScroll 手感)。
/// 坐标即展开进度 [0,1]:撞 0(全堆叠)或 1(全展开)边界立即停;
/// 速度耗尽停在途中(松手带多少力滑多少,慢慢减弱)。
/// 边界保证:fan=0 时前台卡完整在屏内 → 屏幕上恒留至少一个可见视图。
class _FanInertia extends Simulation {
  _FanInertia({required this.start, required this.velocity})
    : _stopT = velocity.abs() / _kDecel;

  /// 减速度(fan 进度/s²):决定惯性滑行时长与距离。
  static const double _kDecel = 12;

  final double start;
  final double velocity;
  final double _stopT;

  double _raw(double t) =>
      start + velocity * t - 0.5 * _kDecel * velocity.sign * t * t;

  @override
  double x(double t) => _raw(t).clamp(0.0, 1.0);

  @override
  double dx(double t) =>
      t >= _stopT ? 0.0 : velocity - _kDecel * velocity.sign * t;

  @override
  bool isDone(double t) {
    final tt = t < _stopT ? t : _stopT;
    final raw = _raw(tt);
    return raw <= 0.0 || raw >= 1.0 || t >= _stopT;
  }
}
