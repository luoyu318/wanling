import 'package:app/models/message.dart';
import 'package:app/providers/agent_sessions_provider.dart' show AgentSessionsNotifier;
import 'package:app/providers/chat_provider.dart';
import 'package:app/providers/chat_state.dart';
import 'package:app/providers/conversation_provider.dart';
import 'package:app/widgets/chat/chat_state_listener.dart';
import 'package:app/widgets/chat/conv_sync_controller.dart';
import 'package:app/widgets/chat/jump_controller.dart';
import 'package:app/widgets/chat/unread_locator_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockWidgetRef extends Mock implements WidgetRef {}

class _MockChatNotifier extends Mock implements ChatNotifier {}

class _MockConvListNotifier extends Mock implements ConversationListNotifier {}

class _MockJumpController extends Mock implements JumpController {}

class _MockConvSync extends Mock implements ConvSyncController {}

class _MockScrollController extends Mock implements ScrollController {}

class _MockScrollPosition extends Mock implements ScrollPosition {}

/// ChatStateListener 不在底部 + 对方新消息分支的依赖较重,
/// 对未参与此分支的依赖提供 throw-on-call fakes,既满足构造约束,
/// 又能在误触发时 fail(防御性)。
class _FakeJumpController extends Fake implements JumpController {}

class _FakeConvSync extends Fake implements ConvSyncController {}

class _FakeUnreadLocator extends Fake implements UnreadLocatorController {
  // 守卫现在会读 isLocating,默认 fake 需返回 false(非定位态),否则既有
  // 测试访问该 getter 会抛 UnimplementedError。
  @override
  bool get isLocating => false;
}

/// 可控 isLocating 的 stub,用于测试未读定位期间禁用跟随的守卫。
class _StubLocator extends Fake implements UnreadLocatorController {
  final bool locating;
  _StubLocator({this.locating = false});
  @override
  bool get isLocating => locating;
}

/// 可控 isMessageInViewport 的 stub,用于聚合卡翻转补 markRead 的
/// 「翻转卡是否在视口内」守卫(替代原 userScrolledAway 语义)。
class _ViewportStubLocator extends Fake implements UnreadLocatorController {
  final bool inViewport;
  _ViewportStubLocator({required this.inViewport});
  @override
  bool get isLocating => false;
  @override
  bool isMessageInViewport(String msgId) => inViewport;
}

ChatMessage _msg(String id, {String senderType = 'agent', bool silent = false}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: senderType,
    senderId: senderType == 'user' ? 'u1' : 'agent-1',
    content: {
      'msg_type': 'markdown',
      'data': {'text': 'msg'},
      if (silent) 'silent': true,
    },
    createdAt: DateTime.utc(2026, 7, 15),
  );
}

/// 卡片消息(running→PATCH 回写内容会增高)。
ChatMessage _card(String id, String preview) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: 'agent',
    senderId: 'agent-1',
    content: {'msg_type': 'card', 'data': {'preview': preview}},
    createdAt: DateTime.utc(2026, 7, 15),
  );
}

/// 聚合卡消息(含 silent 标记,回合结束翻转 true→false)。
ChatMessage _aggregateCard(String id, {bool silent = false}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: 'agent',
    senderId: 'agent-1',
    content: {
      'msg_type': 'aggregate_card',
      'data': {'state': silent ? 'generating' : 'done', 'elements': const []},
      if (silent) 'silent': true,
    },
    createdAt: DateTime.utc(2026, 7, 15),
  );
}

Map<String, dynamic> _streamContent(String text) =>
    {'msg_type': 'markdown', 'data': {'text': text}};

/// 构造一个 ChatStateListenerContext。
/// [userScrolledAway] 控制用户是否主动滚动离开底部(替代原 atBottom 语义:
/// 「不在底部」→ 用户主动离开 = true;未主动离开(含被大消息顶出)= false)。
ChatStateListenerContext _ctx({
  required WidgetRef ref,
  required ChatNotifier notifier,
  bool userScrolledAway = false,
  AgentSessionsNotifier? sessionsNotifier,
  JumpController? jumpController,
  ConvSyncController? convSync,
  ScrollController? scrollController,
  UnreadLocatorController? unreadLocator,
}) {
  return ChatStateListenerContext(
    ref: ref,
    convId: 'c1',
    agentId: 'agent-1',
    chatKey: (convId: 'c1', agentId: 'agent-1'),
    isMounted: () => true,
    onSetState: (_) {},
    getUserScrolledAway: () => userScrolledAway,
    getScrollCtrl: () => scrollController ?? (throw UnimplementedError('getScrollCtrl')),
    getNotifier: () => notifier,
    getSessionsNotifier: () => sessionsNotifier,
    getJumpController: () => jumpController ?? _FakeJumpController(),
    getConvSync: () => convSync ?? _FakeConvSync(),
    getUnreadLocator: () => unreadLocator ?? _FakeUnreadLocator(),
    onRefreshExtraItems: () {},
  );
}

void main() {
  // ========== silent 守卫(与 conversationProvider / agentSessionsProvider /
  // server IncrUnreadTx 四路对齐)==========
  // 场景:用户主动离开底部(userScrolledAway=true) + 对方(agent)新消息,
  // silent 控制是否 incrementUnread。
  group('silent 守卫(用户主动离开底部 + 对方新消息)', () {
    test('silent=true → 不 incrementUnread + 不读 ref', () async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: true, // 用户主动离开底部 → 命中 else 分支
      ));

      // prev 有 1 条旧消息,next 头部新增一条 silent agent 消息(prepend)
      final prev = ChatState(
        historyMessages: [_msg('m-old')],
        isInitialLoading: false,
      );
      final next = ChatState(
        historyMessages: [_msg('m-new', silent: true), _msg('m-old')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      // 等待可能存在的 addPostFrameCallback(silent 分支不应调度,但兜底 flush)
      await Future.delayed(Duration.zero);

      verifyNever(() => notifier.incrementUnread());
      // silent 分支不应读 conversationProvider(若调 ref.read 会抛
      // MissingStubError → 测试 fail,已隐式覆盖,这里显式断言更清晰)
      verifyNever(() => ref.read(conversationProvider.notifier));
    });

    test('silent 缺省(false) → incrementUnread + 同步会话列表', () async {
      final convNotifier = _MockConvListNotifier();
      final ref = _MockWidgetRef();
      when(() => ref.read(conversationProvider.notifier)).thenReturn(convNotifier);
      final notifier = _MockChatNotifier();
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: true,
      ));

      final prev =
          ChatState(historyMessages: [_msg('m-old')], isInitialLoading: false);
      final next = ChatState(
        historyMessages: [_msg('m-new'), _msg('m-old')], // 无 silent 字段
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      await Future.delayed(Duration.zero);

      verify(() => notifier.incrementUnread()).called(1);
      verify(() => convNotifier.incrementUnreadLocally('c1')).called(1);
    });
  });

  // ========== 贴底跟随(方案 A:用户主动滚动离开标志)==========
  // 修复「agent 发卡片后贴底自动跟随失效」:大高度非流式消息(卡片)插入使
  // maxScrollExtent 跳增,但 px 不变、_onScroll 不触发,_isAtBottom 保持旧值;
  // (2) 分支调度的 scrollToBottom 动画又会让 _isAtBottom 在动画窗口内翻 false,
  // 流式跟随依赖 _isAtBottom 而失效。改用「用户主动滚动离开」标志判定跟随,
  // 被动被大消息顶出不视为离开底部。
  group('贴底跟随(userScrolledAway 分流)', () {
    testWidgets('未主动离开底部 + 对方新消息 → 滚底 + 不计数', (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final jumpCtrl = _MockJumpController();
      final convSync = _MockConvSync();
      when(() => jumpCtrl.scrollToBottom()).thenReturn(null);
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        jumpController: jumpCtrl,
        convSync: convSync,
      ));

      final prev =
          ChatState(historyMessages: [_msg('m-old')], isInitialLoading: false);
      final next = ChatState(
        historyMessages: [_msg('m-new'), _msg('m-old')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      // postFrame 只在 hasScheduledFrame 时触发(TestWidgetsFlutterBinding.pump),
      // addPostFrameCallback 本身不调度帧,需手动 scheduleFrame。
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verify(() => jumpCtrl.scrollToBottom()).called(1);
      verifyNever(() => notifier.incrementUnread());
    });

    testWidgets('用户主动离开底部 + 对方新消息 → 计数未读,不滚底', (tester) async {
      final convNotifier = _MockConvListNotifier();
      final ref = _MockWidgetRef();
      when(() => ref.read(conversationProvider.notifier)).thenReturn(convNotifier);
      final notifier = _MockChatNotifier();
      final jumpCtrl = _MockJumpController();
      when(() => jumpCtrl.scrollToBottom()).thenReturn(null);
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: true,
        jumpController: jumpCtrl,
      ));

      final prev =
          ChatState(historyMessages: [_msg('m-old')], isInitialLoading: false);
      final next = ChatState(
        historyMessages: [_msg('m-new'), _msg('m-old')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verifyNever(() => jumpCtrl.scrollToBottom());
      verify(() => notifier.incrementUnread()).called(1);
    });

    testWidgets('未主动离开底部 + 流式消息 → 流式跟随 jumpTo 实时底部', (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final scrollCtrl = _MockScrollController();
      final pos = _MockScrollPosition();
      final convSync = _MockConvSync();
      final jumpCtrl = _MockJumpController();
      when(() => scrollCtrl.hasClients).thenReturn(true);
      when(() => scrollCtrl.position).thenReturn(pos);
      when(() => pos.minScrollExtent).thenReturn(0.0);
      when(() => pos.maxScrollExtent).thenReturn(0.0);
      when(() => pos.viewportDimension).thenReturn(600.0);
      when(() => convSync.markRead()).thenAnswer((_) async {});
      when(() => jumpCtrl.scrollToBottom()).thenReturn(null);
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        scrollController: scrollCtrl,
        convSync: convSync,
        jumpController: jumpCtrl,
      ));

      final prev =
          ChatState(historyMessages: [_msg('m-old')], isInitialLoading: false);
      final next = ChatState(
        liveMessages: [_msg('m-stream').copyWith(isStreaming: true)],
        historyMessages: [_msg('m-old')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verify(() => scrollCtrl.jumpTo(any())).called(1);
    });

    testWidgets('新卡片 prepend + 贴底 → 不启动卡片跟随(入场为淡入,无高度增长)',
        (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final scrollCtrl = _MockScrollController();
      final pos = _MockScrollPosition();
      final convSync = _MockConvSync();
      final jumpCtrl = _MockJumpController();
      when(() => scrollCtrl.hasClients).thenReturn(true);
      when(() => scrollCtrl.position).thenReturn(pos);
      when(() => pos.minScrollExtent).thenReturn(0.0);
      when(() => pos.maxScrollExtent).thenReturn(0.0);
      when(() => pos.viewportDimension).thenReturn(600.0);
      when(() => pos.pixels).thenReturn(0.0);
      when(() => convSync.markRead()).thenAnswer((_) async {});
      when(() => jumpCtrl.scrollToBottom()).thenReturn(null);
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        scrollController: scrollCtrl,
        convSync: convSync,
        jumpController: jumpCtrl,
      ));

      // prev: [card-1(旧)], next: 新卡片 card-2 prepend。
      final prev = ChatState(
        liveMessages: [_card('card-1', 'short')],
        isInitialLoading: false,
      );
      final next = ChatState(
        liveMessages: [
          _card('card-2', 'new long').copyWith(
            createdAt: DateTime.utc(2026, 7, 15, 0, 0, 2),
          ),
          _card('card-1', 'short'),
        ],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      await tester.pump(const Duration(milliseconds: 400));

      // prepend 只走 scrollToBottom(平滑),不启动卡片周期 jumpTo 跟随:
      // EnterExpand 已改为淡入不占布局高度,入场期间无高度增长需要消化,
      // 硬 jumpTo 反而与 scrollToBottom 打架造成"先输出再挪动"闪烁。
      verifyNever(() => scrollCtrl.jumpTo(any()));
    });

    testWidgets('用户主动离开底部 + 流式消息 → 不流式跟随', (tester) async {
      final convNotifier = _MockConvListNotifier();
      final ref = _MockWidgetRef();
      when(() => ref.read(conversationProvider.notifier)).thenReturn(convNotifier);
      final notifier = _MockChatNotifier();
      final scrollCtrl = _MockScrollController();
      when(() => scrollCtrl.hasClients).thenReturn(true);
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: true,
        scrollController: scrollCtrl,
      ));

      final prev =
          ChatState(historyMessages: [_msg('m-old')], isInitialLoading: false);
      final next = ChatState(
        liveMessages: [_msg('m-stream').copyWith(isStreaming: true)],
        historyMessages: [_msg('m-old')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verifyNever(() => scrollCtrl.jumpTo(any()));
    });
  });

  // ========== 卡片 PATCH 增高平滑跟随(非流式 content 更新)==========
  // 卡片 running → PATCH 回写内容增高,是非流式消息的 content 更新:不增加消息
  // 条数 → (2) 分支不触发;无流式共存时流式跟随也不触发 → px 停在旧底部、
  // 位置失真。卡片渲染用 AnimatedSize 平滑增高(高度渐进变化),一次性
  // scrollToBottom 目标会随动画增长而过时 → 改周期 jumpTo 实时底部持续跟随。
  group('卡片 PATCH 增高平滑跟随(非流式 content 更新)', () {
    ChatState _cardState(String preview) => ChatState(
          liveMessages: [_card('card-1', preview)],
          isInitialLoading: false,
        );

    testWidgets('贴底 + 非流式消息 content 更新 → 卡片展开期间持续 jumpTo 跟随',
        (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final scrollCtrl = _MockScrollController();
      final pos = _MockScrollPosition();
      when(() => scrollCtrl.hasClients).thenReturn(true);
      when(() => scrollCtrl.position).thenReturn(pos);
      when(() => pos.minScrollExtent).thenReturn(0.0);
      when(() => pos.maxScrollExtent).thenReturn(0.0);
      when(() => pos.viewportDimension).thenReturn(600.0);
      // 周期跟随读 chatProvider 的 liveMessages 算 liveEmpty。
      when(() => ref.read(chatProvider((convId: 'c1', agentId: 'agent-1'))))
          .thenReturn(_cardState('long preview content increases height'));
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        scrollController: scrollCtrl,
      ));

      listener.onChatStateChanged(
        _cardState('short'),
        _cardState('long preview content increases height'),
      );
      // 卡片展开期间(AnimatedSize ~250ms)周期 jumpTo 跟随,pump 推进时间;
      // 400ms > 320ms 兜底让周期 timer 自停(否则测试结束报 Timer pending)。
      await tester.pump(const Duration(milliseconds: 400));

      verify(() => scrollCtrl.jumpTo(any())).called(greaterThan(0));
    });

    testWidgets('用户主动离开底部 + 非流式 content 更新 → 不打扰', (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final scrollCtrl = _MockScrollController();
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: true,
        scrollController: scrollCtrl,
      ));

      listener.onChatStateChanged(
        _cardState('short'),
        _cardState('long preview content increases height'),
      );
      await tester.pump(const Duration(milliseconds: 80));

      verifyNever(() => scrollCtrl.jumpTo(any()));
    });

    testWidgets('只流式 content 更新(无卡片 PATCH)→ 走流式跟随,不启动卡片跟随',
        (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final scrollCtrl = _MockScrollController();
      final pos = _MockScrollPosition();
      when(() => scrollCtrl.hasClients).thenReturn(true);
      when(() => scrollCtrl.position).thenReturn(pos);
      when(() => pos.minScrollExtent).thenReturn(0.0);
      when(() => pos.maxScrollExtent).thenReturn(0.0);
      when(() => pos.viewportDimension).thenReturn(600.0);
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        scrollController: scrollCtrl,
      ));

      final prev = ChatState(
        liveMessages: [
          _msg('s1').copyWith(isStreaming: true, content: _streamContent('ab')),
        ],
        isInitialLoading: false,
      );
      final next = ChatState(
        liveMessages: [
          _msg('s1').copyWith(isStreaming: true, content: _streamContent('abc')),
        ],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      // pump 推进时间:若错误启动卡片周期跟随,会产生额外 jumpTo → called(1) 失败。
      await tester.pump(const Duration(milliseconds: 80));

      // 仅流式跟随的一次 postFrame jumpTo,无卡片跟随的周期调用。
      verify(() => scrollCtrl.jumpTo(any())).called(1);
    });
  });

  // ========== 未读定位期间禁用跟随(isLocating 守卫)==========
  // 修复「未读定位 jumpTo 翻页窗口期被流式/(2)/(2.5) 跟随抢占 scrollCtrl
  // 导致翻页不收敛、onLocateComplete 迟迟不触发、骨架屏退化为 5s 兜底」。
  // 三处跟随分支统一加 !isLocating 守卫,与 LoadMoreController /
  // UnreadTrackerController 已有守卫对齐。
  group('未读定位期间禁用跟随(isLocating 守卫)', () {
    testWidgets('isLocating=true + 对方新消息(贴底) → 不滚底 + 不 markRead',
        (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final jumpCtrl = _MockJumpController();
      final convSync = _MockConvSync();
      when(() => jumpCtrl.scrollToBottom()).thenReturn(null);
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        jumpController: jumpCtrl,
        convSync: convSync,
        unreadLocator: _StubLocator(locating: true),
      ));

      final prev =
          ChatState(historyMessages: [_msg('m-old')], isInitialLoading: false);
      final next = ChatState(
        historyMessages: [_msg('m-new'), _msg('m-old')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verifyNever(() => jumpCtrl.scrollToBottom());
      verifyNever(() => convSync.markRead());
    });

    testWidgets('isLocating=true + 流式消息 → 不流式跟随', (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final scrollCtrl = _MockScrollController();
      when(() => scrollCtrl.hasClients).thenReturn(true);
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        scrollController: scrollCtrl,
        unreadLocator: _StubLocator(locating: true),
      ));

      final prev =
          ChatState(historyMessages: [_msg('m-old')], isInitialLoading: false);
      final next = ChatState(
        liveMessages: [_msg('m-stream').copyWith(isStreaming: true)],
        historyMessages: [_msg('m-old')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verifyNever(() => scrollCtrl.jumpTo(any()));
    });

    testWidgets('isLocating=true + 非流式 content 更新 → 不启动卡片跟随',
        (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final scrollCtrl = _MockScrollController();
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        scrollController: scrollCtrl,
        unreadLocator: _StubLocator(locating: true),
      ));

      listener.onChatStateChanged(
        ChatState(
          liveMessages: [_card('card-1', 'short')],
          isInitialLoading: false,
        ),
        ChatState(
          liveMessages: [_card('card-1', 'long preview content')],
          isInitialLoading: false,
        ),
      );
      await tester.pump(const Duration(milliseconds: 80));

      verifyNever(() => scrollCtrl.jumpTo(any()));
    });
  });

  // ========== 流式占位→终态替换补 markRead(修复 server 未读残留)==========
  // 根因:实时贴底观看时,STREAM 占位插入触发的 markRead 发生在 server 落库之前
  // (MarkRead 取未读为 0 无效果);终态 MESSAGE_CREATE 落库(+1)后 app 同位置替换
  // 占位、displayMessages 长度不变,(2) 分支 newLen>oldLen 不成立 → 不再 markRead,
  // server 端 unread 逐条累积。修复:检测「占位被终态替换」,贴底时补 markRead。
  group('流式占位→终态替换补 markRead(server 未读归零)', () {
    ChatMessage _placeholder(String streamId) => ChatMessage(
          id: 'stream:$streamId',
          conversationId: 'c1',
          senderType: 'agent',
          senderId: 'agent-1',
          content: _streamContent('完整文本'),
          createdAt: DateTime.utc(2026, 7, 15),
        ).copyWith(isStreaming: true);

    testWidgets('贴底 + 占位被终态替换(长度不变)→ 补 markRead', (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final convSync = _MockConvSync();
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        convSync: convSync,
      ));

      final prev = ChatState(
        liveMessages: [_placeholder('sid-1')],
        isInitialLoading: false,
      );
      // 终态替换占位:长度不变,id 从 stream:sid-1 → server id
      final next = ChatState(
        liveMessages: [_msg('msg-real-1')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verify(() => convSync.markRead()).called(1);
    });

    testWidgets('用户已滚动离开 + 占位被终态替换 → 不 markRead(保持未读)', (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final convSync = _MockConvSync();
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: true,
        convSync: convSync,
      ));

      final prev = ChatState(
        liveMessages: [_placeholder('sid-1')],
        isInitialLoading: false,
      );
      final next = ChatState(
        liveMessages: [_msg('msg-real-1')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verifyNever(() => convSync.markRead());
    });
  });

  group('聚合卡 silent 翻转补 markRead(server 未读归零)', () {
    // 聚合卡翻转同时是 content 变化,会触发 (2.5) 卡片跟随 timer(320ms 自停)。
    // 需提供 scrollController mock 让 timer 内 getScrollCtrl 不 throw,并 pump 走完。
    _MockScrollController scrollMock() {
      final scrollCtrl = _MockScrollController();
      final pos = _MockScrollPosition();
      when(() => scrollCtrl.hasClients).thenReturn(true);
      when(() => scrollCtrl.position).thenReturn(pos);
      when(() => pos.minScrollExtent).thenReturn(0.0);
      when(() => pos.maxScrollExtent).thenReturn(0.0);
      when(() => pos.viewportDimension).thenReturn(600.0);
      return scrollCtrl;
    }

    testWidgets('翻转卡在视口内 → 补 markRead(实时观看语义)', (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final convSync = _MockConvSync();
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final scrollCtrl = scrollMock();
      when(() => ref.read(chatProvider((convId: 'c1', agentId: 'agent-1'))))
          .thenReturn(ChatState(
            liveMessages: [_aggregateCard('agg-1')],
            isInitialLoading: false,
          ));
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: true, // 即使 _userScrolledAway 卡在 true
        convSync: convSync,
        scrollController: scrollCtrl,
        unreadLocator: _ViewportStubLocator(inViewport: true),
      ));

      // 聚合卡生成中(silent=true,server 不计未读)
      final prev = ChatState(
        liveMessages: [_aggregateCard('agg-1', silent: true)],
        isInitialLoading: false,
      );
      // 回合结束翻转(silent:false,server IncrUnread +1)
      final next = ChatState(
        liveMessages: [_aggregateCard('agg-1')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();
      // 走完 (2.5) 卡片跟随 timer(320ms),避免 timersPending 断言失败
      await tester.pump(const Duration(milliseconds: 400));

      verify(() => convSync.markRead()).called(1);
    });

    testWidgets('翻转卡不在视口内 → 不 markRead(保持未读浮标)', (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final convSync = _MockConvSync();
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: true,
        convSync: convSync,
        unreadLocator: _ViewportStubLocator(inViewport: false),
      ));

      final prev = ChatState(
        liveMessages: [_aggregateCard('agg-1', silent: true)],
        isInitialLoading: false,
      );
      final next = ChatState(
        liveMessages: [_aggregateCard('agg-1')],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verifyNever(() => convSync.markRead());
    });

    testWidgets('聚合卡无翻转(都 silent 或都 done)→ 不 markRead', (tester) async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final convSync = _MockConvSync();
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: false,
        convSync: convSync,
      ));

      // 生成中→生成中(无翻转)
      final prev = ChatState(
        liveMessages: [_aggregateCard('agg-1', silent: true)],
        isInitialLoading: false,
      );
      final next = ChatState(
        liveMessages: [_aggregateCard('agg-1', silent: true)],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();

      verifyNever(() => convSync.markRead());
    });
  });

  // ========== 自己发消息(self-echo)后无条件滚底(pendingScroll)==========
  // 需求:用户发送消息后应无条件滚到底看到自己刚发的消息,
  // 不受 userScrolledAway / 未读定位 / 列表状态影响。
  group('self-echo 发送消息后 pendingScroll 滚底', () {
    test('普通场景:用户发消息 → 设置 pendingScroll', () async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
      ));

      final prev =
          ChatState(historyMessages: [_msg('m-old')], isInitialLoading: false);
      final next = ChatState(
        historyMessages: [
          _msg('u-self', senderType: 'user').copyWith(
            createdAt: DateTime.utc(2026, 7, 15, 0, 0, 1),
          ),
          _msg('m-old'),
        ],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);

      expect(listener.pendingScroll, isTrue);
    });

    test('用户已滚动离开 + 发消息 → 仍设置 pendingScroll(无条件滚底)', () async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        userScrolledAway: true,
      ));

      final prev =
          ChatState(historyMessages: [_msg('m-old')], isInitialLoading: false);
      final next = ChatState(
        historyMessages: [
          _msg('u-self', senderType: 'user').copyWith(
            createdAt: DateTime.utc(2026, 7, 15, 0, 0, 1),
          ),
          _msg('m-old'),
        ],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);

      expect(listener.pendingScroll, isTrue);
    });

    test('有未读定位 + 发消息 → 仍设置 pendingScroll(定位后也应滚底)', () async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final convSync = _MockConvSync();
      when(() => convSync.markRead()).thenAnswer((_) async {});
      // 首次 state 带未读 → 触发分支(1) 置 _didLocateUnread=true
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        convSync: convSync,
        unreadLocator: _StubLocator(locating: false),
      ));

      // 第一次:进入会话,带未读
      listener.onChatStateChanged(
        null,
        ChatState(
          historyMessages: [_msg('m-old')],
          firstUnreadMessageId: 'm-old',
          isInitialLoading: false,
        ),
      );

      // 用户发送消息(self-echo)
      final prev = ChatState(
        historyMessages: [_msg('m-old')],
        firstUnreadMessageId: 'm-old',
        isInitialLoading: false,
      );
      final next = ChatState(
        historyMessages: [
          _msg('u-self', senderType: 'user').copyWith(
            createdAt: DateTime.utc(2026, 7, 15, 0, 0, 1),
          ),
          _msg('m-old'),
        ],
        firstUnreadMessageId: 'm-old',
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);

      expect(listener.pendingScroll, isTrue);
    });

    test('liveMessages 有新消息 + 发消息 → 设置 pendingScroll', () async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
      ));

      final prev = ChatState(
        liveMessages: [_msg('m-old')],
        isInitialLoading: false,
      );
      // 用户发消息进 liveMessages 末尾(最新)
      final next = ChatState(
        liveMessages: [
          _msg('m-old'),
          _msg('u-self', senderType: 'user').copyWith(
            createdAt: DateTime.utc(2026, 7, 15, 0, 0, 1),
          ),
        ],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);

      expect(listener.pendingScroll, isTrue);
    });

    test('真实路径:进入有未读会话(已置 _didLocateUnread) + 定位动画中发消息 → 滚底',
        () async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final convSync = _MockConvSync();
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        convSync: convSync,
        unreadLocator: _StubLocator(locating: true),
      ));

      // 进入有未读会话:prev=null → next 带未读,分支(1)触发 _didLocateUnread=true
      listener.onChatStateChanged(
        null,
        ChatState(
          historyMessages: [_msg('m-old')],
          firstUnreadMessageId: 'm-old',
          isInitialLoading: false,
        ),
      );

      // 定位动画中(isLocating=true)用户发消息 → 应滚底
      final prev = ChatState(
        historyMessages: [_msg('m-old')],
        firstUnreadMessageId: 'm-old',
        isInitialLoading: false,
      );
      final next = ChatState(
        historyMessages: [
          _msg('u-self', senderType: 'user').copyWith(
            createdAt: DateTime.utc(2026, 7, 15, 0, 0, 1),
          ),
          _msg('m-old'),
        ],
        firstUnreadMessageId: 'm-old',
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);

      expect(listener.pendingScroll, isTrue);
    });

    test('未读定位进行中(isLocating) + 发消息 → 定位结束后仍应滚底', () async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final convSync = _MockConvSync();
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        convSync: convSync,
        unreadLocator: _StubLocator(locating: true),
      ));

      // 首次 state 带未读 → 触发分支(1) 置 _didLocateUnread=true
      listener.onChatStateChanged(
        null,
        ChatState(
          historyMessages: [_msg('m-old')],
          firstUnreadMessageId: 'm-old',
          isInitialLoading: false,
        ),
      );

      final prev = ChatState(
        historyMessages: [_msg('m-old')],
        firstUnreadMessageId: 'm-old',
        isInitialLoading: false,
      );
      final next = ChatState(
        historyMessages: [
          _msg('u-self', senderType: 'user').copyWith(
            createdAt: DateTime.utc(2026, 7, 15, 0, 0, 1),
          ),
          _msg('m-old'),
        ],
        firstUnreadMessageId: 'm-old',
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);

      expect(listener.pendingScroll, isTrue);
    });

    test('BUG 复现:进入会话定位未完成即发消息 → self-echo 被守卫拦截不滚底',
        () async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final convSync = _MockConvSync();
      when(() => convSync.markRead()).thenAnswer((_) async {});
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
        convSync: convSync,
        unreadLocator: _StubLocator(locating: true),
      ));

      // 模拟进入有未读会话的瞬间(分支1已置 _didLocateUnread=true,
      // 但定位动画 isLocating=true 仍在进行),用户立刻发消息。
      listener.onChatStateChanged(
        null,
        ChatState(
          historyMessages: [_msg('m-old')],
          firstUnreadMessageId: 'm-old',
          isInitialLoading: false,
        ),
      );

      final prev = ChatState(
        historyMessages: [_msg('m-old')],
        firstUnreadMessageId: 'm-old',
        isInitialLoading: false,
      );
      final next = ChatState(
        historyMessages: [
          _msg('u-self', senderType: 'user').copyWith(
            createdAt: DateTime.utc(2026, 7, 15, 0, 0, 1),
          ),
          _msg('m-old'),
        ],
        firstUnreadMessageId: 'm-old',
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);

      expect(listener.pendingScroll, isTrue);
    });

    test('BUG 复现:createdAt 相同 + 排序不稳定 → self-echo 被误判为对方消息',
        () async {
      final ref = _MockWidgetRef();
      final notifier = _MockChatNotifier();
      final listener = ChatStateListener(_ctx(
        ref: ref,
        notifier: notifier,
      ));

      final prev = ChatState(
        historyMessages: [_msg('m-old')],
        isInitialLoading: false,
      );
      // 用户消息与已有消息 createdAt 完全相同 → displayMessages 排序不稳定,
      // first 可能不是用户消息 → self-echo 判定失败。
      final next = ChatState(
        historyMessages: [
          _msg('u-self', senderType: 'user'), // 与 m-old 同 createdAt
          _msg('m-old'),
        ],
        isInitialLoading: false,
      );

      listener.onChatStateChanged(prev, next);

      // 需求:无条件滚底。若 pendingScroll 为 false 说明被误判拦截。
      expect(listener.pendingScroll, isTrue);
    });
  });
}
