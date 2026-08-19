import 'package:wanling_core/models/message.dart';
import 'package:app/providers/chat_state.dart';
import 'package:app/providers/chat_provider.dart' show ChatNotifier;
import 'package:wanling_core/services/api_service.dart';
import 'package:app/widgets/chat/jump_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollview_observer/scrollview_observer.dart';

/// 构造一个最小可用的 [JumpContext],所有 getter 默认抛错,
/// 测试用 overrides 替换需要的字段。
JumpContext _buildContext({
  BuildContext Function()? getContext,
  WidgetRef? ref,
  ({String convId, String? agentId})? chatKey,
  void Function(VoidCallback)? onSetState,
  bool Function()? isMounted,
  ScrollController Function()? getScrollCtrl,
  bool Function()? getLiveEmpty,
  SliverObserverController Function()? getObserverController,
  BuildContext? Function()? getLiveSliverContext,
  BuildContext? Function()? getHistorySliverContext,
  Map<String, GlobalKey> Function()? getBubbleKeys,
}) {
  return JumpContext(
    getContext: getContext ?? (() => throw UnimplementedError()),
    ref: ref ?? _DummyRef(),
    chatKey: chatKey ?? (convId: 'c1', agentId: null),
    onSetState: onSetState ?? ((f) => f()),
    isMounted: isMounted ?? (() => true),
    getScrollCtrl: getScrollCtrl ?? (() => throw UnimplementedError()),
    getLiveEmpty: getLiveEmpty ?? (() => false),
    getObserverController:
        getObserverController ?? (() => throw UnimplementedError()),
    getLiveSliverContext: getLiveSliverContext ?? (() => null),
    getHistorySliverContext: getHistorySliverContext ?? (() => null),
    getBubbleKeys: getBubbleKeys ?? (() => {}),
  );
}

ChatMessage _textMsg({
  required String id,
  String text = 'hi',
  String senderId = 'me',
}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: 'user',
    senderId: senderId,
    content: {'msg_type': 'text', 'data': {'text': text}},
    createdAt: DateTime.now(),
    status: MessageStatus.sent,
  );
}

/// 跑 [task] 同时 pump 推进帧,让 task 内部 `await endOfFrame` 能完成。
/// 控制器多个 await 点(endOfFrame / ensureVisible)各需一帧,pump 多次兜底。
Future<void> _runAndPump(WidgetTester tester, Future<void> Function() task) async {
  final future = task();
  for (var i = 0; i < 8; i++) {
    await tester.pump(Duration.zero);
  }
  await future;
}

/// 占位 [WidgetRef]:测试中不触发 ref.read 时使用,noSuchMethod 默认抛错。
class _DummyRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 可编程 [WidgetRef]:按返回类型分发 read。
/// - ChatState → 预设值
/// - ApiService → 预设 fake
/// - ChatNotifier → 预设 stub
/// 其他调用走 noSuchMethod 抛错(测试若误触达会立刻暴露)。
class _StubRef implements WidgetRef {
  _StubRef({required ChatState chatState, ApiService? api, ChatNotifier? notifier})
      : _chatState = chatState,
        _api = api,
        _notifier = notifier;

  final ChatState _chatState;
  final ApiService? _api;
  final ChatNotifier? _notifier;

  @override
  T read<T>(ProviderListenable<T> provider) {
    if (T == ChatState) return _chatState as T;
    if (T == ApiService) {
      return (_api ?? _ThrowingApi()) as T;
    }
    if (T == ChatNotifier) return (_notifier ?? _NoopNotifier()) as T;
    throw UnimplementedError('Unexpected read for type $T');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 记录 mergeJumpedContext 调用次数,其他走 noSuchMethod。
class _NoopNotifier implements ChatNotifier {
  int mergeCalls = 0;
  @override
  void mergeJumpedContext(MessageContext ctx) => mergeCalls++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 可配置的 [ApiService] fake:getMessageContext 抛预设异常或返预设结果。
class _FakeApi implements ApiService {
  _FakeApi({this.error, this.result});
  final Object? error;
  final MessageContext? result;
  int calls = 0;

  @override
  Future<MessageContext> getMessageContext(
    String messageId, {
    int before = 10,
    int after = 10,
  }) async {
    calls++;
    if (error != null) throw error!;
    return result!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// getMessageContext 调用时抛 [UnimplementedError](用于断言「不应被调用」)。
class _ThrowingApi implements ApiService {
  @override
  Future<MessageContext> getMessageContext(
    String messageId, {
    int before = 10,
    int after = 10,
  }) async {
    throw UnimplementedError('api.getMessageContext should not be called');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// pump 一个最小 MaterialApp 拿 BuildContext,供 snackbar 测试。
Future<BuildContext> _pumpMinimalContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            captured = ctx;
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  group('highlightedMessageId', () {
    test('初始为 null', () {
      final ctrl = JumpController(_buildContext());
      expect(ctrl.highlightedMessageId, isNull);
      ctrl.dispose();
    });
  });

  group('highlightMessage', () {
    test('设置 id → highlightedMessageId == messageId', () {
      final ctrl = JumpController(_buildContext());
      ctrl.highlightMessage('m1');
      expect(ctrl.highlightedMessageId, 'm1');
      ctrl.dispose();
    });

    test('unmounted 时 no-op(不调 onSetState)', () {
      var setStateCalls = 0;
      final ctrl = JumpController(_buildContext(
        onSetState: (f) {
          setStateCalls++;
          f();
        },
        isMounted: () => false,
      ));
      ctrl.highlightMessage('m1');
      expect(setStateCalls, 0);
      expect(ctrl.highlightedMessageId, isNull);
      ctrl.dispose();
    });

    testWidgets('1s 后清空(Timer fire)', (tester) async {
      final ctrl = JumpController(_buildContext());
      ctrl.highlightMessage('m1');
      expect(ctrl.highlightedMessageId, 'm1');
      await tester.pump(const Duration(seconds: 1));
      expect(ctrl.highlightedMessageId, isNull);
    });

    testWidgets('dispose 中 cancel Timer → 不清空', (tester) async {
      final ctrl = JumpController(_buildContext());
      ctrl.highlightMessage('m1');
      expect(ctrl.highlightedMessageId, 'm1');
      ctrl.dispose();
      await tester.pump(const Duration(seconds: 1));
      // dispose 已 cancel Timer,清空回调不执行,id 保留
      expect(ctrl.highlightedMessageId, 'm1');
    });

    testWidgets('重复高亮覆盖旧 id + 重置 Timer', (tester) async {
      final ctrl = JumpController(_buildContext());
      ctrl.highlightMessage('m1');
      await tester.pump(const Duration(milliseconds: 600));
      ctrl.highlightMessage('m2');
      expect(ctrl.highlightedMessageId, 'm2');
      // m1 的 timer 已 cancel,m2 的 1s 从此刻起算
      await tester.pump(const Duration(milliseconds: 600));
      expect(ctrl.highlightedMessageId, 'm2');
      await tester.pump(const Duration(milliseconds: 400));
      expect(ctrl.highlightedMessageId, isNull);
    });
  });

  group('scrollToBottom', () {
    test('无 clients → no-op(不抛异常)', () {
      final scrollCtrl = ScrollController();
      final ctrl = JumpController(_buildContext(
        getScrollCtrl: () => scrollCtrl,
      ));
      ctrl.scrollToBottom(); // 不应抛
      ctrl.dispose();
    });

    testWidgets('已在底部(|maxExtent-px|<=5) → no-op 不动画', (tester) async {
      final scrollCtrl = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              controller: scrollCtrl,
              children: List.generate(
                5,
                (_) => const SizedBox(height: 50),
              ),
            ),
          ),
        ),
      );
      expect(scrollCtrl.hasClients, isTrue);
      // 内容铺满视口,maxScrollExtent=0,px=0 → 已在底部
      expect(scrollCtrl.position.pixels, 0);
      expect(scrollCtrl.position.maxScrollExtent, 0);
      final ctrl = JumpController(_buildContext(
        getScrollCtrl: () => scrollCtrl,
      ));
      ctrl.scrollToBottom();
      await tester.pump();
      expect(scrollCtrl.position.pixels, 0); // 未动
    });

    testWidgets('需要滚动 → animateTo 到 maxScrollExtent', (tester) async {
      final scrollCtrl = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: ListView(
                controller: scrollCtrl,
                children: List.generate(
                  20,
                  (_) => const SizedBox(height: 50),
                ),
              ),
            ),
          ),
        ),
      );
      // 下滑制造离底部的距离
      scrollCtrl.jumpTo(120);
      final maxExtent = scrollCtrl.position.maxScrollExtent;
      expect((maxExtent - scrollCtrl.position.pixels).abs(), greaterThan(5));
      final ctrl = JumpController(_buildContext(
        getScrollCtrl: () => scrollCtrl,
      ));
      ctrl.scrollToBottom();
      await tester.pumpAndSettle();
      expect(scrollCtrl.position.pixels, maxExtent);
    });
  });

  group('jumpToMessage', () {
    testWidgets('本地命中 → 不调 api,scrollToMessageIndex + highlightMessage',
        (tester) async {
      // scrollToMessageIndex 依赖 observerController,测试里 sliverContexts
      // 为空 → 等一帧 → 仍空 → 早返。验证 highlightMessage 被调用即可。
      final observerCtrl = SliverObserverController(
        controller: ScrollController(),
      );
      final ref = _StubRef(
        // m1 放活跃段 → 本地命中(liveMessages)
        chatState: ChatState(liveMessages: [_textMsg(id: 'm1')]),
        // api 不传 → 默认 _ThrowingApi,若被调用会抛 → 测试失败
      );
      final ctrl = JumpController(_buildContext(
        ref: ref,
        getObserverController: () => observerCtrl,
        getBubbleKeys: () => {},
      ));
      // 不能直接 await:jumpToMessage 内部 await endOfFrame 需 pump 推进帧。
      await _runAndPump(tester, () => ctrl.jumpToMessage('m1'));
      expect(ctrl.highlightedMessageId, 'm1');
      ctrl.dispose();
    });

    testWidgets('本地未命中 → 调 api + mergeJumpedContext + 正在跳转提示',
        (tester) async {
      final capturedCtx = await _pumpMinimalContext(tester);
      final notifier = _NoopNotifier();
      final api = _FakeApi(
        result: MessageContext(
          target: _textMsg(id: 'm2'),
          before: const [],
          after: const [],
        ),
      );
      // chatState 不含 m2 → 本地未命中;merge 后第二次读仍不含(只验证调用链)
      final ref = _StubRef(
        chatState: const ChatState(),
        api: api,
        notifier: notifier,
      );
      final observerCtrl = SliverObserverController(
        controller: ScrollController(),
      );
      final ctrl = JumpController(_buildContext(
        getContext: () => capturedCtx,
        ref: ref,
        getObserverController: () => observerCtrl,
        getBubbleKeys: () => {},
      ));
      await _runAndPump(tester, () => ctrl.jumpToMessage('m2'));
      expect(api.calls, 1, reason: '本地未命中应调 api.getMessageContext');
      expect(notifier.mergeCalls, 1, reason: '应调 mergeJumpedContext');
      expect(find.text('正在跳转...'), findsOneWidget);
      ctrl.dispose();
    });

    testWidgets('404(MessageNotFoundException)→ 原消息已删除', (tester) async {
      final capturedCtx = await _pumpMinimalContext(tester);
      final api = _FakeApi(error: MessageNotFoundException());
      final ref = _StubRef(
        chatState: const ChatState(),
        api: api,
      );
      final observerCtrl = SliverObserverController(
        controller: ScrollController(),
      );
      final ctrl = JumpController(_buildContext(
        getContext: () => capturedCtx,
        ref: ref,
        getObserverController: () => observerCtrl,
        getBubbleKeys: () => {},
      ));
      await _runAndPump(tester, () => ctrl.jumpToMessage('mX'));
      expect(find.text('原消息已删除'), findsOneWidget);
      ctrl.dispose();
    });

    testWidgets('403(NoAccessException)→ 无权查看此消息', (tester) async {
      final capturedCtx = await _pumpMinimalContext(tester);
      final api = _FakeApi(error: NoAccessException());
      final ref = _StubRef(
        chatState: const ChatState(),
        api: api,
      );
      final observerCtrl = SliverObserverController(
        controller: ScrollController(),
      );
      final ctrl = JumpController(_buildContext(
        getContext: () => capturedCtx,
        ref: ref,
        getObserverController: () => observerCtrl,
        getBubbleKeys: () => {},
      ));
      await _runAndPump(tester, () => ctrl.jumpToMessage('mX'));
      expect(find.text('无权查看此消息'), findsOneWidget);
      ctrl.dispose();
    });

    testWidgets('其他异常 → 跳转失败提示', (tester) async {
      final capturedCtx = await _pumpMinimalContext(tester);
      final api = _FakeApi(error: Exception('boom'));
      final ref = _StubRef(
        chatState: const ChatState(),
        api: api,
      );
      final observerCtrl = SliverObserverController(
        controller: ScrollController(),
      );
      final ctrl = JumpController(_buildContext(
        getContext: () => capturedCtx,
        ref: ref,
        getObserverController: () => observerCtrl,
        getBubbleKeys: () => {},
      ));
      await _runAndPump(tester, () => ctrl.jumpToMessage('mX'));
      expect(find.textContaining('跳转失败'), findsOneWidget);
      ctrl.dispose();
    });
  });

  group('dispose', () {
    test('dispose 不抛异常(无 pending Timer)', () {
      final ctrl = JumpController(_buildContext());
      ctrl.dispose(); // 不应抛
    });

    test('dispose 后再 dispose 安全(幂等)', () {
      final ctrl = JumpController(_buildContext());
      ctrl.dispose();
      ctrl.dispose(); // 不应抛
    });
  });

  group('scrollToBottom 提前返回边界', () {
    testWidgets('BUG 验证:目标已含新内容,但 px 恰在底部容差内 → no-op(不再滚)',
        (tester) async {
      // 模拟双 sliver 场景:发送新消息后 postFrame 时刻新消息尚未被布局,
      // maxScrollExtent 未包含其高度 → target≈px → abs()<=5 → 提前 return。
      // 后续没有其他滚动调用,用户看到新消息停留在视口下方。
      final scrollCtrl = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(
                controller: scrollCtrl,
                children: List.generate(
                  10,
                  (_) => const SizedBox(height: 50),
                ),
              ),
            ),
          ),
        ),
      );
      // 停在中间,距底部 > 5
      scrollCtrl.jumpTo(100);
      final before = scrollCtrl.position.pixels;
      final ctrl = JumpController(_buildContext(
        getScrollCtrl: () => scrollCtrl,
        getLiveEmpty: () => false,
      ));
      ctrl.scrollToBottom();
      await tester.pumpAndSettle();
      // 会滚到底(正常)
      expect(scrollCtrl.position.pixels, scrollCtrl.position.maxScrollExtent);
      ctrl.dispose();
    });

    testWidgets('二次校准:首次滚动后新内容布局 → 动画结束自动再滚到底',
        (tester) async {
      // 真实场景模拟:内容很多,第一次 scrollToBottom 滚到当前 maxScrollExtent,
      // 期间新消息(高 item)布局进来使 maxScrollExtent 增长 → 二次校准应再滚。
      final scrollCtrl = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: ListView(
                controller: scrollCtrl,
                children: List.generate(
                  10,
                  (_) => const SizedBox(height: 50),
                ),
              ),
            ),
          ),
        ),
      );
      scrollCtrl.jumpTo(50); // 离底部
      await tester.pump(); // 让 jumpTo 就绪
      final maxExtent = scrollCtrl.position.maxScrollExtent;
      final ctrl = JumpController(_buildContext(
        getScrollCtrl: () => scrollCtrl,
        getLiveEmpty: () => false,
      ));
      ctrl.scrollToBottom();
      await tester.pumpAndSettle(); // 跑完第一次动画 + 二次校准递归
      // 此时应已在底部
      expect(scrollCtrl.position.pixels, maxExtent);
      ctrl.dispose();
    });

    testWidgets('回归:流式增长不死循环(二次校准后不再递归)', (tester) async {
      // 模拟 agent 流式回复:二次校准后 maxScrollExtent 又增长,验证 scrollToBottom
      // 只做一次二次校准就停(不会无限 animateTo → UI 卡死)。
      final scrollCtrl = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 200,
              child: ListView(
                controller: scrollCtrl,
                children: List.generate(
                  10,
                  (_) => const SizedBox(height: 50),
                ),
              ),
            ),
          ),
        ),
      );
      scrollCtrl.jumpTo(50);
      await tester.pump();
      final ctrl = JumpController(_buildContext(
        getScrollCtrl: () => scrollCtrl,
        getLiveEmpty: () => false,
      ));

      ctrl.scrollToBottom();
      // 推进多次,让第一次动画 + 二次校准都完成。
      // 若实现存在递归死循环,此处会一直有 pending 动画 → pumpAndSettle 永不结束。
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      final pxAfterCalibration = scrollCtrl.position.pixels;
      // 再推进足够时间,px 应保持稳定(二次校准后不再有新的 animateTo)。
      await tester.pump(const Duration(milliseconds: 600));
      expect(scrollCtrl.position.pixels, pxAfterCalibration,
          reason: '二次校准后不应再滚动');
      ctrl.dispose();
    });

    testWidgets('BUG 复现:滚动目标 == 当前 px(内容刚够一屏)→ no-op',
        (tester) async {
      // 关键场景:live 非空但内容刚好铺满视口 → maxScrollExtent=0,px=0,
      // |target-px|<=5 → 提前 return。此时若新消息高度 > cacheExtent 尚未布局,
      // 发送后不滚底。
      final scrollCtrl = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 300,
              child: ListView(
                controller: scrollCtrl,
                children: List.generate(
                  6,
                  (_) => const SizedBox(height: 50),
                ),
              ),
            ),
          ),
        ),
      );
      // 300px 视口,6*50=300px 内容 → maxScrollExtent=0
      expect(scrollCtrl.position.maxScrollExtent, 0);
      final ctrl = JumpController(_buildContext(
        getScrollCtrl: () => scrollCtrl,
        getLiveEmpty: () => false,
      ));
      ctrl.scrollToBottom();
      await tester.pump();
      // 已在底部(内容不够滚动),无动画
      expect(scrollCtrl.position.pixels, 0);
      ctrl.dispose();
    });
  });

  group('dualSliverBottomTarget(双 sliver 底部目标 px)', () {
    test('live 非空 → maxScrollExtent(正向 sliver 末尾)', () {
      expect(
        dualSliverBottomTarget(
          minScrollExtent: -1000,
          maxScrollExtent: 200,
          viewportDimension: 600,
          liveEmpty: false,
        ),
        200,
      );
    });

    test('live 空 + 历史够长(>1屏) → -vd(newest 贴 viewport 底)', () {
      expect(
        dualSliverBottomTarget(
          minScrollExtent: -1000,
          maxScrollExtent: 0,
          viewportDimension: 600,
          liveEmpty: true,
        ),
        -600,
      );
    });

    test('live 空 + 历史不足1屏 → minScrollExtent(clamp 防越界)', () {
      expect(
        dualSliverBottomTarget(
          minScrollExtent: -200,
          maxScrollExtent: 0,
          viewportDimension: 600,
          liveEmpty: true,
        ),
        -200,
      );
    });

    test('live 非空 但 maxScrollExtent<vd(消息不足1屏) → 仍返 maxScrollExtent', () {
      expect(
        dualSliverBottomTarget(
          minScrollExtent: -100,
          maxScrollExtent: 80,
          viewportDimension: 600,
          liveEmpty: false,
        ),
        80,
      );
    });
  });
}
