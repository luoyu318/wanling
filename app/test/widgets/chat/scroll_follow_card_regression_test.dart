import 'package:app/widgets/chat/jump_controller.dart' show dualSliverBottomTarget;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「卡片消息插入后贴底自动跟随失效」的机制回归测试(修复后行为)。
///
/// 背景(修复前):
/// 1. Flutter 中 maxScrollExtent 变化只 dispatch ScrollMetricsNotification,不通知
///    ScrollController listener(见 scroll_position.dart didUpdateScrollMetrics)
///    → 消息 prepend 时 px 不变,_onScroll 不触发,_isAtBottom 保持旧值。
/// 2. 卡片(大高度非流式消息)插入后 (2) 分支调度 scrollToBottom(animateTo 动画),
///    动画窗口内 px 移动 → _onScroll 触发 → _isAtBottom 翻 false。
/// 3. 流式跟随依赖 _isAtBottom,动画窗口内 + 动画目标过时(流式增长前移)后持续
///    false → 永久失效。
///
/// 修复(方案 A):引入「用户主动滚动离开底部」标志,流式跟随改用
/// `!_userScrolledAway` 判定。卡片等被动顶出不改变该标志,动画也不影响,跟随持续。
///
/// 本测试用真实双 sliver center 几何复刻 _onScroll 公式 + 修复后的跟随条件,
/// 验证:卡片插入 + 流式增长场景,未主动滚动时跟随保持(px 始终贴实时底部);
/// 用户主动拖动离开后,跟随停止。
class _Sim extends StatefulWidget {
  const _Sim({super.key, required this.heights});
  final List<double> heights;

  @override
  State<_Sim> createState() => _SimState();
}

class _SimState extends State<_Sim> {
  late final ScrollController _ctrl = ScrollController();
  bool isAtBottom = false;

  /// 复刻 chat_page._userScrolledAway:用户拖动开始置 true,停稳回底复位。
  bool userScrolledAway = false;

  /// 模拟 chat_page 的 isScrollingNotifier:拖动/惯性期间禁止复位 userScrolledAway。
  bool userScrolling = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 复刻 ChatPage._onScroll 的 _isAtBottom 公式 + 非拖动期贴底复位 userScrolledAway。
  void _onScroll() {
    final pos = _ctrl.position;
    final px = pos.pixels;
    final bottom = dualSliverBottomTarget(
      minScrollExtent: pos.minScrollExtent,
      maxScrollExtent: pos.maxScrollExtent,
      viewportDimension: pos.viewportDimension,
      liveEmpty: widget.heights.isEmpty,
    );
    final was = isAtBottom;
    isAtBottom = (px - bottom).abs() <= 50;
    if (isAtBottom && !userScrolling) userScrolledAway = false;
    if (was != isAtBottom) setState(() {});
  }

  /// 复刻 ChatPage._handleScrollNotification:用户拖动开始。
  void userDragStart() {
    userScrolling = true;
    userScrolledAway = true;
  }

  /// 复刻惯性滚动结束(ScrollEndNotification dragDetails==null):
  /// 拖动期结束,若已回到底部则恢复跟随。
  void userScrollEnded() {
    userScrolling = false;
    if (isAtBottom) userScrolledAway = false;
  }

  /// 复刻 JumpController.scrollToBottom((2) 分支在贴底+新消息时调度)。
  void scrollToBottom() {
    final pos = _ctrl.position;
    _ctrl.animateTo(
      dualSliverBottomTarget(
        minScrollExtent: pos.minScrollExtent,
        maxScrollExtent: pos.maxScrollExtent,
        viewportDimension: pos.viewportDimension,
        liveEmpty: widget.heights.isEmpty,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 复刻 ChatStateListener 流式跟随(修复后:仅用户未主动离开底部时 jumpTo)。
  void streamingFollow() {
    if (!userScrolledAway) {
      final pos = _ctrl.position;
      _ctrl.jumpTo(pos.maxScrollExtent);
    }
  }

  void jumpToBottom() {
    final pos = _ctrl.position;
    _ctrl.jumpTo(pos.maxScrollExtent);
  }

  void jumpTo(double px) => _ctrl.jumpTo(px);

  double get pixels => _ctrl.position.pixels;
  double get maxExtent => _ctrl.position.maxScrollExtent;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          controller: _ctrl,
          center: const ValueKey('live'),
          slivers: [
            SliverList(
              key: const ValueKey('live'),
              delegate: SliverChildBuilderDelegate(
                (_, i) => SizedBox(height: widget.heights[i]),
                childCount: widget.heights.length,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets(
    '修复:卡片插入 + 动画窗口内流式,未主动滚动 → 跟随保持(px 贴实时底部)',
    (tester) async {
      final key = GlobalKey<_SimState>();
      // 12 条 60px = 720px > 视口 600px,确保 maxScrollExtent > 0。
      await tester.pumpWidget(
          _Sim(key: key, heights: List.filled(12, 60.0)));
      var state = key.currentState!;
      state.jumpToBottom();
      await tester.pump();
      expect(state.isAtBottom, isTrue);
      expect(state.userScrolledAway, isFalse);

      // ---- 1. 卡片一次性插入(300px) ----
      await tester.pumpWidget(
          _Sim(key: key, heights: [...List.filled(12, 60.0), 300.0]));
      state = key.currentState!;
      await tester.pump();
      // 物理机制:maxExt 增长但 px 不变 → _onScroll 不触发 → 位置状态保持;
      // 修复后跟随条件(userScrolledAway)不受影响,仍保持未离开。
      expect(state.userScrolledAway, isFalse,
          reason: '卡片被动顶出不改变 userScrolledAway');

      // ---- 2. (2) 分支调度 scrollToBottom 动画,动画窗口内流式开始 ----
      state.scrollToBottom();
      await tester.pump(); // 启动 ticker
      await tester.pump(const Duration(milliseconds: 50)); // 动画中,px 移动
      expect(state.isAtBottom, isFalse,
          reason: '动画窗口内 _isAtBottom 翻 false(修复前失效的诱因)');

      // 流式首块 + 增长,每次流式跟随都贴实时底部。
      await tester.pumpWidget(_Sim(
          key: key,
          heights: [...List.filled(12, 60.0), 300.0, 40.0]));
      state = key.currentState!;
      await tester.pump(const Duration(milliseconds: 100));
      state.streamingFollow();
      await tester.pump();

      await tester.pumpWidget(_Sim(
          key: key,
          heights: [...List.filled(12, 60.0), 300.0, 40.0, 40.0, 40.0]));
      state = key.currentState!;
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      // ---- 3. 断言:跟随保持,px 贴实时底部(不再失效) ----
      state.streamingFollow();
      await tester.pump();
      expect((state.pixels - state.maxExtent).abs(), lessThanOrEqualTo(50),
          reason: '修复后:卡片 + 流式场景,未主动滚动时 px 始终贴实时底部');
      expect(state.isAtBottom, isTrue);
    },
  );

  testWidgets('对照:用户主动拖动离开后,新消息不再自动跟随', (tester) async {
    final key = GlobalKey<_SimState>();
    await tester.pumpWidget(_Sim(key: key, heights: List.filled(12, 60.0)));
    var state = key.currentState!;
    state.jumpToBottom();
    await tester.pump();
    expect(state.isAtBottom, isTrue);

    // 用户主动上滑离开底部:拖动开始 → 上滑到中途 → 惯性停稳(停在中间)。
    state.userDragStart();
    final pxBeforeDragAway = state.pixels;
    state.jumpTo(60.0); // 上滑到中间,触发 _onScroll 重算
    await tester.pump();
    state.userScrollEnded(); // 惯性结束,停在中间(isAtBottom=false)→ 保持离开态
    expect(state.userScrolledAway, isTrue,
        reason: '拖动期结束但仍不在底部,_userScrolledAway 应保持 true');
    expect(60.0, lessThan(pxBeforeDragAway), reason: '前提:用户确实上滑离开底部');

    // 新消息到达 + 流式跟随:userScrolledAway=true → 不 jumpTo,位置保持。
    await tester.pumpWidget(_Sim(
        key: key,
        heights: [...List.filled(12, 60.0), 300.0, 40.0, 40.0]));
    state = key.currentState!;
    await tester.pump();
    final pxBefore = state.pixels;
    state.streamingFollow();
    await tester.pump();
    expect(state.pixels, pxBefore,
        reason: '用户主动离开底部后流式跟随停止,位置不被新消息拉走');
    expect(pxBefore, lessThan(pxBeforeDragAway),
        reason: '前提:用户确实滚动离开了底部');
  });

  testWidgets(
    '回归:拖动中仍处底部容差内时,userScrolledAway 不被复位(上滑停得住)',
    (tester) async {
      final key = GlobalKey<_SimState>();
      await tester.pumpWidget(_Sim(key: key, heights: List.filled(12, 60.0)));
      var state = key.currentState!;
      state.jumpToBottom();
      await tester.pump();
      expect(state.isAtBottom, isTrue);

      // 用户开始拖动上滑,但手指刚移动、px 仍处底部 50px 容差内。
      state.userDragStart(); // userScrolling=true, userScrolledAway=true
      state.jumpTo(80.0); // bottom=120, |80-120|=40 <= 50 → isAtBottom 仍 true
      await tester.pump();
      expect(state.isAtBottom, isTrue, reason: '前提:还在底部容差内');
      expect(state.userScrolledAway, isTrue,
          reason: '拖动期不得被 _onScroll 复位(旧逻辑在此误复位导致跟随抢回)');

      // 流式增长中,流式跟随不得把内容拉回底部。
      await tester.pumpWidget(_Sim(
          key: key,
          heights: [...List.filled(12, 60.0), 300.0, 40.0, 40.0]));
      state = key.currentState!;
      await tester.pump();
      final pxBefore = state.pixels;
      state.streamingFollow();
      await tester.pump();
      expect(state.pixels, pxBefore,
          reason: '拖动期(即使仍处底部容差内)流式跟随不触发,上滑停得住');
    },
  );
}
