import 'package:app/models/message.dart';
import 'package:app/widgets/chat/message_menu_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一个最小可用的 [MessageMenuContext],所有回调默认 no-op 或返 stub。
/// 测试用 `overrides` 替换需要的字段。
MessageMenuContext _buildContext({
  Rect? Function(String msgId)? bubbleGlobalRect,
  List<ChatMessage> Function()? getMessages,
  String Function()? getCurrentUserId,
  Future<void> Function(ChatMessage msg)? onCopySelectedOrFull,
  Future<void> Function(List<String> ids, {bool recall})? onConfirmDelete,
  void Function(String msgId)? onEnterSelectionMode,
  VoidCallback? onMenuHide,
  bool Function()? getIsAgentSession,
  BuildContext Function()? getContext,
  GlobalKey Function()? getListViewKey,
}) {
  return MessageMenuContext(
    getContext: getContext ?? (() => throw UnimplementedError()),
    getListViewKey: getListViewKey ?? (() => GlobalKey()),
    bubbleGlobalRect: bubbleGlobalRect ?? (_) => null,
    getMessages: getMessages ?? () => const [],
    getCurrentUserId: getCurrentUserId ?? () => 'me',
    onCopySelectedOrFull: onCopySelectedOrFull ?? (_) async {},
    onConfirmDelete: onConfirmDelete ?? (_, {bool recall = false}) async {},
    onEnterSelectionMode: onEnterSelectionMode ?? (_) {},
    onMenuHide: onMenuHide ?? () {},
    getIsAgentSession: getIsAgentSession ?? () => false,
    chatKey: (convId: 'c1', agentId: null),
    ref: _DummyRef(),
  );
}

ChatMessage _msg({
  required String id,
  String senderId = 'me',
  DateTime? createdAt,
  MessageStatus status = MessageStatus.sent,
}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: 'user',
    senderId: senderId,
    content: {'msg_type': 'text', 'data': {'text': 'hi'}},
    createdAt: createdAt ?? DateTime.now(),
    status: status,
  );
}

/// 防止 MessageMenuContext.ref 字段类型校验失败的占位 WidgetRef。
/// 测试中不触发 ref.read/write,所以这里只是类型 stub。
class _DummyRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('canRecall', () {
    test('自己发的 + sent + 5min 内 → true', () {
      final ctrl = MessageMenuController(_buildContext());
      expect(
        ctrl.canRecall(_msg(
          id: 'm1',
          senderId: 'me',
          createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
          status: MessageStatus.sent,
        )),
        isTrue,
      );
    });

    test('别人发的 → false', () {
      final ctrl = MessageMenuController(_buildContext());
      expect(
        ctrl.canRecall(_msg(
          id: 'm1',
          senderId: 'someone-else',
          createdAt: DateTime.now(),
        )),
        isFalse,
      );
    });

    test('status != sent → false', () {
      final ctrl = MessageMenuController(_buildContext());
      expect(
        ctrl.canRecall(_msg(
          id: 'm1',
          status: MessageStatus.sending,
        )),
        isFalse,
      );
      expect(
        ctrl.canRecall(_msg(
          id: 'm1',
          status: MessageStatus.failed,
        )),
        isFalse,
      );
    });

    test('超过 5 分钟 → false', () {
      final ctrl = MessageMenuController(_buildContext());
      expect(
        ctrl.canRecall(_msg(
          id: 'm1',
          createdAt: DateTime.now().subtract(const Duration(minutes: 6)),
        )),
        isFalse,
      );
    });

    test('恰好 5 分钟边界 → 接近边界用 4:59 / 5:01 验证', () {
      final ctrl = MessageMenuController(_buildContext());
      // 用 4:59 / 5:01 避免 DateTime.now() 两次调用之间的时钟漂移导致 flaky。
      expect(
        ctrl.canRecall(_msg(
          id: 'm1',
          createdAt: DateTime.now().subtract(
            const Duration(minutes: 4, seconds: 59),
          ),
        )),
        isTrue,
      );
      expect(
        ctrl.canRecall(_msg(
          id: 'm1',
          createdAt: DateTime.now().subtract(
            const Duration(minutes: 5, seconds: 1),
          ),
        )),
        isFalse,
      );
    });

    test('getCurrentUserId 为空 → false(防 senderId == "" 误命中)', () {
      final ctrl = MessageMenuController(
        _buildContext(getCurrentUserId: () => ''),
      );
      expect(
        ctrl.canRecall(_msg(id: 'm1', senderId: '')),
        isFalse,
      );
    });
  });

  group('hideMessageMenu', () {
    test('触发 onMenuHide callback', () {
      var hidden = 0;
      final ctrl = MessageMenuController(
        _buildContext(onMenuHide: () => hidden++),
      );
      ctrl.hideMessageMenu();
      expect(hidden, 1);
    });

    test('未打开菜单时调用也是安全的(不抛)', () {
      final ctrl = MessageMenuController(_buildContext());
      ctrl.hideMessageMenu();
      expect(ctrl.isMenuOpen, isFalse);
    });
  });

  group('showMessageMenu', () {
    testWidgets('bubbleGlobalRect 返回 null → no-op(不创建 OverlayEntry)',
        (tester) async {
      late MessageMenuController captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                captured = MessageMenuController(
                  _buildContext(
                    getContext: () => ctx,
                    bubbleGlobalRect: (_) => null,
                  ),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      captured.showMessageMenu(_msg(id: 'm1'));
      await tester.pump();
      expect(captured.isMenuOpen, isFalse);
    });

    testWidgets('消息在可见区 → 创建 OverlayEntry', (tester) async {
      late MessageMenuController captured;
      late BuildContext ctxRef;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                ctxRef = ctx;
                captured = MessageMenuController(
                  _buildContext(
                    getContext: () => ctx,
                    bubbleGlobalRect: (_) => const Rect.fromLTWH(
                      20,
                      100,
                      100,
                      40,
                    ),
                  ),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      captured.showMessageMenu(_msg(id: 'm1'));
      await tester.pump();
      expect(captured.isMenuOpen, isTrue);
      // 验证 OverlayEntry 真的插入到了 Overlay 里
      expect(captured, isNotNull);
      expect(ctxRef, isNotNull);
      // 通过 isMenuOpen 间接验证 _menuEntry != null
    });

    testWidgets('菜单打开后再调用 showMessageMenu 会先关闭旧菜单',
        (tester) async {
      late MessageMenuController captured;
      var hideCallCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                captured = MessageMenuController(
                  _buildContext(
                    getContext: () => ctx,
                    bubbleGlobalRect: (_) => const Rect.fromLTWH(
                      20,
                      100,
                      100,
                      40,
                    ),
                    onMenuHide: () => hideCallCount++,
                  ),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      captured.showMessageMenu(_msg(id: 'm1'));
      await tester.pump();
      expect(captured.isMenuOpen, isTrue);
      // showMessageMenu 内部先调 hideMessageMenu 清旧态(首次 +1)
      expect(hideCallCount, 1);

      // 切换到另一条消息:第二次 showMessageMenu 会先 hide 旧菜单(再 +1)
      captured.showMessageMenu(_msg(id: 'm2'));
      await tester.pump();
      expect(captured.isMenuOpen, isTrue);
      expect(hideCallCount, 2);
    });
  });

  group('agent_session 场景(引用/撤回隐藏)', () {
    testWidgets('agent_session + 消息在可见区 → 菜单只有复制/删除/多选,无引用/撤回',
        (tester) async {
      late MessageMenuController captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                captured = MessageMenuController(
                  _buildContext(
                    getContext: () => ctx,
                    getIsAgentSession: () => true,
                    bubbleGlobalRect: (_) => const Rect.fromLTWH(
                      20,
                      100,
                      100,
                      40,
                    ),
                  ),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      // 自己发的 + sent + 5min 内,即使 canRecall=true 也因 agent_session 隐藏撤回。
      captured.showMessageMenu(_msg(
        id: 'm1',
        senderId: 'me',
        createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
        status: MessageStatus.sent,
      ));
      await tester.pump();
      expect(captured.isMenuOpen, isTrue);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('多选'), findsOneWidget);
      expect(find.text('引用'), findsNothing);
      expect(find.text('撤回'), findsNothing);
    });

    testWidgets('agent_session + 滚动重算后菜单仍不显示引用/撤回', (tester) async {
      late MessageMenuController captured;
      final messages = <ChatMessage>[_msg(id: 'm1', senderId: 'me')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                captured = MessageMenuController(
                  _buildContext(
                    getContext: () => ctx,
                    getIsAgentSession: () => true,
                    bubbleGlobalRect: (_) => const Rect.fromLTWH(
                      20,
                      100,
                      100,
                      40,
                    ),
                    getMessages: () => messages,
                  ),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      captured.showMessageMenu(_msg(id: 'm1', senderId: 'me'));
      await tester.pump();
      expect(captured.isMenuOpen, isTrue);

      captured.updateMenuOnScroll();
      await tester.pump();
      expect(captured.isMenuOpen, isTrue);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('多选'), findsOneWidget);
      expect(find.text('引用'), findsNothing);
      expect(find.text('撤回'), findsNothing);
    });

    testWidgets('普通会话(非 agent_session)仍显示引用/撤回', (tester) async {
      late MessageMenuController captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                captured = MessageMenuController(
                  _buildContext(
                    getContext: () => ctx,
                    getIsAgentSession: () => false,
                    bubbleGlobalRect: (_) => const Rect.fromLTWH(
                      20,
                      100,
                      100,
                      40,
                    ),
                  ),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      captured.showMessageMenu(_msg(
        id: 'm1',
        senderId: 'me',
        createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
        status: MessageStatus.sent,
      ));
      await tester.pump();
      expect(captured.isMenuOpen, isTrue);
      expect(find.text('引用'), findsOneWidget);
      expect(find.text('撤回'), findsOneWidget);
    });
  });

  group('updateMenuOnScroll', () {
    test('菜单未打开时调用 → no-op(不抛、不读 messages)', () {
      var messagesCalled = false;
      final ctrl = MessageMenuController(
        _buildContext(
          getMessages: () {
            messagesCalled = true;
            return [];
          },
        ),
      );
      ctrl.updateMenuOnScroll();
      expect(messagesCalled, isFalse,
          reason: '菜单未开时应早返,不查 messages');
    });

    testWidgets('messages 变空 + 菜单打开时 → hideMessageMenu 清理悬空菜单',
        (tester) async {
      late MessageMenuController captured;
      var hideCallCount = 0;
      var messages = <ChatMessage>[_msg(id: 'm1')];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                captured = MessageMenuController(
                  _buildContext(
                    getContext: () => ctx,
                    bubbleGlobalRect: (_) => const Rect.fromLTWH(
                      20,
                      100,
                      100,
                      40,
                    ),
                    getMessages: () => messages,
                    onMenuHide: () => hideCallCount++,
                  ),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      // 先打开菜单(messages 非空,showMessageMenu 内部 hide 一次 → hideCallCount=1)
      captured.showMessageMenu(_msg(id: 'm1'));
      await tester.pump();
      expect(captured.isMenuOpen, isTrue);
      expect(hideCallCount, 1);

      // 消息全删,messages 变空(模拟菜单打开后消息被批量删除)
      messages = const [];

      // 滚动重算应命中 isEmpty 守卫,调 hideMessageMenu 清理悬空菜单
      captured.updateMenuOnScroll();
      await tester.pump();
      expect(captured.isMenuOpen, isFalse);
      expect(hideCallCount, 2);
    });
  });

  group('dispose', () {
    test('未打开菜单时调用安全(不抛)', () {
      final ctrl = MessageMenuController(_buildContext());
      ctrl.dispose();
      expect(ctrl.isMenuOpen, isFalse);
    });

    testWidgets('菜单打开时 dispose 移除 OverlayEntry', (tester) async {
      late MessageMenuController captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) {
                captured = MessageMenuController(
                  _buildContext(
                    getContext: () => ctx,
                    bubbleGlobalRect: (_) => const Rect.fromLTWH(
                      20,
                      100,
                      100,
                      40,
                    ),
                  ),
                );
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      captured.showMessageMenu(_msg(id: 'm1'));
      await tester.pump();
      expect(captured.isMenuOpen, isTrue);

      captured.dispose();
      expect(captured.isMenuOpen, isFalse);
    });
  });

  group('isMenuOpen', () {
    test('新构造的 controller 默认未打开', () {
      final ctrl = MessageMenuController(_buildContext());
      expect(ctrl.isMenuOpen, isFalse);
    });
  });
}
