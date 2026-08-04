import 'package:app/models/message.dart';
import 'package:app/providers/chat_provider.dart';
import 'package:app/providers/chat_state.dart';
import 'package:app/widgets/chat/unread_locator_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scrollview_observer/scrollview_observer.dart';

class _MockWidgetRef extends Mock implements WidgetRef {}

class _MockScrollController extends Mock implements ScrollController {}

class _MockScrollPosition extends Mock implements ScrollPosition {}

/// observer 用 throw-on-call fake:贴底分支(修复目标)不应触碰 observer.jumpTo,
/// 若回归到 30% 对齐路径会因误触而 fail(防御性)。
class _ThrowingObserver extends Fake implements SliverObserverController {
  @override
  bool get isForbidObserveViewportCallback => false;

  @override
  set isForbidObserveViewportCallback(bool _) {}

  @override
  List<BuildContext> get sliverContexts => throw UnimplementedError(
      '贴底分支不应读 sliverContexts(否则回归到 30% 对齐路径)');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('贴底分支不应调用 observer: ${invocation.memberName}');
}

ChatMessage _msg(String id) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: 'agent',
    senderId: 'agent-1',
    content: {
      'msg_type': 'markdown',
      'data': {'text': 'msg'},
    },
    createdAt: DateTime.utc(2026, 7, 15),
  );
}

void main() {
  const chatKey = (convId: 'c1', agentId: 'agent-1');

  // ========== 纯函数:computeTargetPx 自算目标 px(替代 ensureVisible)==========
  // 背景:ensureVisible(0.3) 对超高 markdown 会滚过头,把 markdown 顶部推出视口
  // (需手动下滑才看到)。改为屏幕几何自算:目标顶部对齐视口 alignment 处。
  group('computeTargetPx 屏幕几何自算', () {
    test('markdown 在视口下方(需上移)→ px 增大,顶部对齐 30%', () {
      // 视口 [100, 100+600], markdown 顶部当前在屏幕 700(视口下方)
      // 30% 处 = 100 + 0.3*600 = 280。markdown 顶部要移到 280:上移 420px。
      final px = computeTargetPx(
        currentPx: -1000,
        targetTop: 700,
        viewportTop: 100,
        viewportHeight: 600,
        alignment: 0.3,
      );
      // 屏幕移动量 = 700 - 280 = 420(上移)→ px 增大 420
      expect(px, closeTo(-580, 0.001));
    });

    test('markdown 顶部已在视口 30% 处 → px 不变', () {
      final px = computeTargetPx(
        currentPx: -1000,
        targetTop: 280,
        viewportTop: 100,
        viewportHeight: 600,
        alignment: 0.3,
      );
      expect(px, closeTo(-1000, 0.001));
    });

    test('markdown 在视口上方(顶部超出视口,需下滑)→ px 减小', () {
      // markdown 顶部当前在屏幕 50(视口上方),30% 处 = 280
      // 屏幕移动量 = 50 - 280 = -230(下移)→ px 减小 230
      final px = computeTargetPx(
        currentPx: -1000,
        targetTop: 50,
        viewportTop: 100,
        viewportHeight: 600,
        alignment: 0.3,
      );
      expect(px, closeTo(-1230, 0.001));
    });

    test('alignment=0 → 顶部对齐视口顶(无上方历史填充时)', () {
      final px = computeTargetPx(
        currentPx: -1000,
        targetTop: 700,
        viewportTop: 100,
        viewportHeight: 600,
        alignment: 0,
      );
      // 屏幕移动量 = 700 - 100 = 600 → px = -400
      expect(px, closeTo(-400, 0.001));
    });
  });

  // ========== 修复:未读不足一屏/未读即最新时定位偏差 ==========
  // 现象:firstUnread 是 historyMessages.first(最新历史,index==0)时,
  // observer.jumpTo(alignment:0.3) 判定目标已在视口只滚一小段(px≈-34.8),
  // 30% 对齐从未执行 → history 底部 + live 顶部同时露出(上下 sliver 各半)。
  // 修复:index==0 时退化为贴底(dualSliverBottomTarget),与无未读场景 B 一致。
  group('firstUnread 即最新历史(index==0)时定位', () {
    testWidgets('直接贴底:跳 dualSliverBottomTarget,不触碰 observer.jumpTo',
        (tester) async {
      final ref = _MockWidgetRef();
      final scrollCtrl = _MockScrollController();
      final pos = _MockScrollPosition();
      when(() => ref.read(chatProvider(chatKey)))
          .thenReturn(ChatState(
            historyMessages: [_msg('m0'), _msg('m1'), _msg('m2')],
            firstUnreadMessageId: 'm0',
            unreadCount: 1,
          ));
      when(() => scrollCtrl.hasClients).thenReturn(true);
      when(() => scrollCtrl.position).thenReturn(pos);
      // 双 sliver center 几何:live 空 → 贴底目标 = max(minScrollExtent, -vd)
      when(() => pos.minScrollExtent).thenReturn(-758.0);
      when(() => pos.maxScrollExtent).thenReturn(0.0);
      when(() => pos.viewportDimension).thenReturn(758.0);
      var located = false;

      final locator = UnreadLocatorController(UnreadLocatorContext(
        ref: ref,
        chatKey: chatKey,
        isMounted: () => true,
        getScrollCtrl: () => scrollCtrl,
        getObserverController: () => _ThrowingObserver(),
        getHistorySliverContext: () => throw UnimplementedError(),
        getBubbleKeys: () => <String, GlobalKey>{},
        getListViewKey: () => GlobalKey(),
        getContext: () => throw UnimplementedError(),
        onLocateComplete: () => located = true,
      ));

      locator.scrollToFirstUnreadIfNeeded();
      WidgetsBinding.instance.scheduleFrame();
      await tester.pump();
      await tester.pump();

      // 贴底目标 = max(-758, -758) = -758(视口顶),不依赖 observer 的 30% 对齐。
      verify(() => scrollCtrl.jumpTo(-758.0)).called(1);
      expect(located, isTrue, reason: '贴底完成后应触发 onLocateComplete');
    });
  });
}
