// 小程序面板 + 消息页下拉手势作用域(mockups/mp-multitask 交互移植)。
//
// 消息页下拉入口交互:
// - 页面是顶层卡片:下拉全程跟手下推,顶缘圆角 18*p 渐现,随下拉压暗
// - 面板是底层:8%~45% 区间淡入 + 0.96→1.0 微缩放,完成态才可交互
// - 松手分档:>=190 震动补完打开 / >=60 轻拉刷新 / <60 弹回
// - 完成态:底栏由宿主按 panelOpenNotifier 收缩(高度 64→0),页头贴底成为
//   返回条;上滑跟手恢复(拖过半松手收回),点页头/系统返回收回
// - 注意:顶部下拉时 OverscrollNotification.overscroll 为负值(踩坑)
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';

import 'package:app/providers/mini_program_manager_provider.dart';
import 'avatar.dart';

/// 面板网格项(最近/常用统一视图模型)。
typedef _MpEntry = ({String appid, String name, String iconUrl});

/// 消息页下拉手势作用域。
///
/// 包在 `_MsgNavPage` 的 body 外层:[header] 为页头(随卡片下推,完成态
/// 贴底作返回条),[child] 为页面内容(其内部滚动列表在顶部下拉时驱动手势)。
/// [panelOpenNotifier] 暴露完成态给宿主(HomePage 据此收缩底栏)。
class MiniProgramPullScope extends StatefulWidget {
  const MiniProgramPullScope({
    super.key,
    required this.panelOpenNotifier,
    required this.header,
    required this.onRefresh,
    required this.onOpenApp,
    required this.child,
  });

  /// 完成态信号:宿主(HomePage)监听后把底栏高度收到 0。
  final ValueNotifier<bool> panelOpenNotifier;

  /// 页头 widget(消息页为 buildHomeAppBar 产物,AppBar 自带 SafeArea)。
  final Widget header;

  /// 轻拉(>=60px)松手触发的刷新。
  final Future<void> Function() onRefresh;

  /// 点面板图标打开小程序(调用方经 openMiniProgramWith 统一入口)。
  final ValueChanged<String> onOpenApp;

  /// 页面内容。
  final Widget child;

  @override
  State<MiniProgramPullScope> createState() => _MiniProgramPullScopeState();
}

class _MiniProgramPullScopeState extends State<MiniProgramPullScope>
    with SingleTickerProviderStateMixin {
  static const double _headerH = kToolbarHeight; // 页头(AppBar)高度
  static const double _panelThreshold = 190; // 松手补完打开阈值
  static const double _refreshThreshold = 60; // 轻拉刷新阈值
  static const double _refreshHoldH = 64; // 刷新期间页面保持的下移量

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  double _pull = 0; // 页面当前下移量
  double _animFrom = 0;
  double _animTo = 0;
  bool _panelOpen = false; // 面板完成态
  bool _refreshing = false;
  double _bodyH = 0;
  int _segment = 0; // 下拉跨段触感:0 无 / 1 刷新段 / 2 面板段

  /// 系统底部手势条 inset:外层 Scaffold 带 bottomNavigationBar 时 body 的
  /// MediaQuery bottom 被剥掉,完成态贴底位置须从 View 层取真实 inset。
  double get _systemPadBottom {
    final v = View.of(context);
    return v.padding.bottom / v.devicePixelRatio;
  }

  /// 完成态下移量:状态栏 + 页头正好推到屏幕底(手势条上方)。
  /// dots 不占布局空间(改揭示带覆盖),完成态落位只由页头决定。
  double get _tMax {
    final padTop = MediaQuery.paddingOf(context).top;
    return (_bodyH - padTop - _headerH - _systemPadBottom).clamp(
      0.0,
      double.infinity,
    );
  }

  @override
  void initState() {
    super.initState();
    _settle.addListener(() {
      setState(() {
        // 打开完成态时底栏同步收缩,body 高度逐帧变化,
        // 目标位必须取实时 _tMax,否则停在旧几何的落位(mockup 踩坑)
        final to = _panelOpen ? _tMax : _animTo;
        _pull =
            _animFrom +
            (to - _animFrom) * Curves.easeOutCubic.transform(_settle.value);
      });
    });
    // settle 完成帧直接贴合实时目标位:解除「settle 300ms > 底栏收缩 250ms」
    // 的时序假设,底栏先/后收完,末帧都精确落到最终贴底位
    _settle.addStatusListener((status) {
      if (status != AnimationStatus.completed) return;
      setState(() => _pull = _panelOpen ? _tMax : _animTo);
    });
    // notifier 双向同步:宿主(HomePage 切页 onPageChanged 兜底)可外部复位,
    // 本地完成态跟随收回/打开,保持单源一致。内部变更经 _setPanelOpen 写入
    // 相同值,ValueNotifier 不重复通知,无回环。
    widget.panelOpenNotifier.addListener(_onExternalNotifier);
  }

  /// 外部(宿主)修改 notifier 时同步本地状态:置 false 收回面板(动画回弹),
  /// 置 true 直接进完成态并补完到贴底位。
  void _onExternalNotifier() {
    if (!mounted) return;
    final external = widget.panelOpenNotifier.value;
    if (external == _panelOpen) return;
    if (external) {
      _panelOpen = true;
      _animatePullTo(_tMax);
    } else {
      _closePanel();
    }
  }

  @override
  void dispose() {
    widget.panelOpenNotifier.removeListener(_onExternalNotifier);
    _settle.dispose();
    super.dispose();
  }

  void _animatePullTo(double to) {
    _animFrom = _pull;
    _animTo = to;
    _settle.forward(from: 0);
  }

  void _setPanelOpen(bool v) {
    _panelOpen = v;
    widget.panelOpenNotifier.value = v;
  }

  /// 下拉跨段(无/刷新/面板)边界给 selectionClick 触感。
  void _segmentHaptic() {
    final seg = _pull >= _panelThreshold
        ? 2
        : (_pull >= _refreshThreshold ? 1 : 0);
    if (seg != _segment) {
      _segment = seg;
      HapticFeedback.selectionClick();
    }
  }

  bool _onOverscroll(OverscrollNotification n) {
    if (_panelOpen || _refreshing || _settle.isAnimating) return false;
    // 只认主列表(纵向)在顶部的下拉:顶部下拉 overscroll 为负值,正向
    // (底部回弹)与横向轮播的 overscroll 一律忽略
    if (n.metrics.axisDirection != AxisDirection.down) return false;
    if (n.overscroll >= 0) return false;
    if (n.metrics.pixels > n.metrics.minScrollExtent) return false;
    setState(() {
      _pull = (_pull - n.overscroll).clamp(0.0, _tMax);
    });
    _segmentHaptic();
    return false;
  }

  bool _onScrollEnd(ScrollEndNotification n) {
    if (_panelOpen || _refreshing || _settle.isAnimating) return false;
    // 安全前提:本回调对通知源不作源校验,依赖 _pull 只能经 _onOverscroll
    // 累积(该处已过滤横向/非顶部 overscroll),嵌套滚动源(横幅轮播等)的
    // ScrollEnd 在 _pull==0 时全部落入末尾 no-op 分支,无副作用。
    _segment = 0;
    if (_pull >= _panelThreshold) {
      HapticFeedback.mediumImpact();
      _setPanelOpen(true);
      _animatePullTo(_tMax);
    } else if (_pull >= _refreshThreshold) {
      unawaited(_doRefresh());
    } else if (_pull > 0) {
      _animatePullTo(0);
    }
    return false;
  }

  /// 轻拉刷新:页面保持 64px 下移转圈,与最短 900ms 展示并行(mockup 口径)。
  Future<void> _doRefresh() async {
    setState(() => _refreshing = true);
    _animatePullTo(0);
    try {
      await Future.wait([
        Future<void>.sync(widget.onRefresh),
        Future<void>.delayed(const Duration(milliseconds: 900)),
      ]);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _closePanel() {
    if (!_panelOpen) return;
    _setPanelOpen(false);
    _animatePullTo(0);
  }

  /// 完成态面板上滑:页面跟手恢复。
  void _onPanelDragUpdate(double dy) {
    if (!_panelOpen || _settle.isAnimating) return;
    setState(() => _pull = (_pull + dy).clamp(0.0, _tMax));
  }

  void _onPanelDragEnd(double velocity) {
    if (!_panelOpen || _settle.isAnimating) return;
    if (velocity < -500 || _pull < _tMax * 0.5) {
      _closePanel();
    } else {
      _animatePullTo(_tMax);
    }
  }

  void _openAppFromPanel(String appid) {
    widget.onOpenApp(appid);
    _closePanel();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _bodyH = constraints.maxHeight;
        final t = _refreshing ? _refreshHoldH : _pull;
        final tMax = _tMax;
        final p = tMax <= 0 ? 0.0 : (t / tMax).clamp(0.0, 1.0);
        // 面板淡入:下拉 8% 起显,45% 全显
        final panelVis = _panelOpen ? 1.0 : ((p - 0.08) / 0.45).clamp(0.0, 1.0);

        return PopScope(
          canPop: !_panelOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _closePanel();
          },
          child: Stack(
            children: [
              // 底层:小程序面板(淡入+微缩放,完成态才可交互)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: panelVis < 1,
                  child: Transform.scale(
                    scale: 0.96 + 0.04 * panelVis,
                    child: Opacity(
                      opacity: panelVis,
                      child: MiniProgramPanel(
                        onOpenApp: _openAppFromPanel,
                        onDragUpdate: _onPanelDragUpdate,
                        onDragEnd: _onPanelDragEnd,
                      ),
                    ),
                  ),
                ),
              ),
              // 顶层:页面卡片(整页跟手下推;完成态页头区点击收回)
              Positioned.fill(
                child: Transform.translate(
                  key: const ValueKey('pull-card'),
                  offset: Offset(0, t),
                  child: ClipRRect(
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(18 * p),
                    ),
                      child: Stack(
                        children: [
                          Column(
                            children: [
                              // 完成态整条页头是返回条:点击收回,
                              // AbsorbPointer 屏蔽 AppBar 内部按钮
                              if (_panelOpen)
                                GestureDetector(
                                  onTap: _closePanel,
                                  child: AbsorbPointer(
                                    child: widget.header,
                                  ),
                                )
                              else
                                widget.header,
                              Expanded(
                              child:
                                  NotificationListener<ScrollEndNotification>(
                                    onNotification: _onScrollEnd,
                                    child:
                                        NotificationListener<
                                          OverscrollNotification
                                        >(
                                          onNotification: _onOverscroll,
                                          child: widget.child,
                                        ),
                                  ),
                            ),
                          ],
                        ),
                        // 随下拉轻微压暗(对照下推页面的灰化)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.18 * p),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 揭示带 dots:不占布局空间,覆盖元素垂直居中于「屏幕顶到
              // 下推卡片顶缘」的带内(与下方刷新 spinner 同层方式);
              // p 0.02→0.10 跟手淡入,0.10→0.35 跟手淡出交接面板,背景透明
              if (!_panelOpen && _dotsOpacityOf(p) > 0)
                Positioned(
                  key: const ValueKey('pull-dots'),
                  left: 0,
                  right: 0,
                  top: 0,
                  height: t,
                  child: Center(
                    child: Opacity(
                      opacity: _dotsOpacityOf(p),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _Dot(),
                          SizedBox(width: 4.0 + p * 26.0),
                          const _Dot(),
                          SizedBox(width: 4.0 + p * 26.0),
                          const _Dot(),
                        ],
                      ),
                    ),
                  ),
                ),
              // 轻拉刷新:页面下移留出的顶部条带中央转圈
              if (_refreshing)
                const Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: _refreshHoldH,
                  child: Center(
                    child: SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 揭示带 dots 透明度:p≤0.02 或 p≥0.35 时 0;0.02→0.10 淡入、
  /// 0.10→0.35 淡出(交接底层面板),两段都跟手。
  double _dotsOpacityOf(double p) {
    final fadeIn = ((p - 0.02) / 0.08).clamp(0.0, 1.0);
    final fadeOut = (1 - ((p - 0.10) / 0.25)).clamp(0.0, 1.0);
    return fadeIn < fadeOut ? fadeIn : fadeOut;
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 7,
      height: 7,
      decoration: const BoxDecoration(
        color: Color(0xFF333333),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// 底层小程序面板:「最近使用」(保活实例,空则整段隐藏)+「常用的小程序」
/// (miniProgramsProvider 前 8 个),4 列网格;图标样式对照
/// mini_program_list_page 的 _MpTile(Avatar size 56 / radius 14)。
class MiniProgramPanel extends ConsumerWidget {
  const MiniProgramPanel({
    super.key,
    required this.onOpenApp,
    this.onDragUpdate,
    this.onDragEnd,
  });

  final ValueChanged<String> onOpenApp;

  /// 上滑跟手恢复:delta.dy(向下为正)。
  final ValueChanged<double>? onDragUpdate;

  /// 上滑松手:纵向速度(px/s)。
  final ValueChanged<double>? onDragEnd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baseUrl = ref.watch(apiProvider).baseUrl;
    final all =
        ref.watch(miniProgramsProvider).valueOrNull ??
        const <MiniProgramInfo>[];
    final recent = [
      for (final inst in ref.watch(miniProgramManagerProvider).list)
        _lookupEntry(inst.appid, inst.name, inst.iconUrl, all, baseUrl),
    ];
    final common = [
      for (final mp in all.take(8))
        (appid: mp.appid, name: mp.name, iconUrl: mp.iconUrlFor(baseUrl)),
    ];

    return GestureDetector(
      // 上滑:页面跟手恢复
      onVerticalDragUpdate: onDragUpdate == null
          ? null
          : (d) => onDragUpdate!(d.delta.dy),
      onVerticalDragEnd: onDragEnd == null
          ? null
          : (d) => onDragEnd!(d.primaryVelocity ?? 0),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xF0241F2E), Color(0xF0171320)],
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 18),
                const Center(
                  child: Text(
                    '最近',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                // 搜索框(占位,入口后续接入)
                Container(
                  height: 42,
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  alignment: Alignment.center,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search, color: Colors.white38, size: 20),
                      SizedBox(width: 6),
                      Text(
                        '搜索小程序',
                        style: TextStyle(color: Colors.white38, fontSize: 14),
                      ),
                    ],
                  ),
                ),
                if (recent.isNotEmpty) ...[
                  const _SectionHeader('最近使用'),
                  _iconGrid(recent),
                ],
                if (common.isNotEmpty) ...[
                  const _SectionHeader('常用的小程序'),
                  _iconGrid(common),
                ],
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 实例元信息(name/iconUrl)为空时回退查 miniProgramsProvider 注册条目。
  _MpEntry _lookupEntry(
    String appid,
    String instName,
    String instIconUrl,
    List<MiniProgramInfo> all,
    String baseUrl,
  ) {
    MiniProgramInfo? mp;
    for (final m in all) {
      if (m.appid == appid) {
        mp = m;
        break;
      }
    }
    final name = instName.isNotEmpty ? instName : (mp?.name ?? appid);
    final iconUrl = instIconUrl.isNotEmpty
        ? instIconUrl
        : (mp?.iconUrlFor(baseUrl) ?? '');
    return (appid: appid, name: name, iconUrl: iconUrl);
  }

  Widget _iconGrid(List<_MpEntry> items) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        childAspectRatio: 0.86,
        children: [
          for (final it in items)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onOpenApp(it.appid),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Avatar(
                    name: it.name,
                    url: it.iconUrl.isEmpty ? null : it.iconUrl,
                    size: 56,
                    radius: 14,
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 72,
                    child: Text(
                      it.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
    child: Text(
      title,
      style: const TextStyle(color: Colors.white54, fontSize: 13),
    ),
  );
}
