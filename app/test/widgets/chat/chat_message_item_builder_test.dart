import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_state.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:app/widgets/chat/chat_message_item_builder.dart';
import 'package:app/widgets/chat/enter_expand.dart';
import 'package:app/widgets/chat/file_download_controller.dart';
import 'package:app/widgets/chat/jump_controller.dart';
import 'package:app/widgets/chat/message_menu_controller.dart';
import 'package:app/widgets/chat/multi_select_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockMenu extends Mock implements MessageMenuController {}
class _MockMulti extends Mock implements MultiSelectController {}
class _MockFile extends Mock implements FileDownloadController {}
class _MockJump extends Mock implements JumpController {}
class _MockRef extends Mock implements WidgetRef {}

ChatMessage _mkMsg({
  required String msgType,
  required String status,
  String? parentMsgId,
  String id = 'm1',
}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: 'agent',
    senderId: 'a1',
    content: {
      'msg_type': msgType,
      'data': {'status': status, 'action': 'bash'},
    },
    parentMsgId: parentMsgId,
    createdAt: DateTime.parse('2026-07-15T10:00:00Z'),
  );
}

void main() {
  group('ChatMessageItemBuilder pending 子审批卡隐藏', () {
    testWidgets('pending 子审批卡 → SizedBox.shrink(不渲染完整行)', (tester) async {
      final pendingChild = _mkMsg(
        msgType: 'permission_card',
        status: 'pending',
        parentMsgId: 'task-card-1',
      );

      final ctx = ChatMessageItemBuildContext(
        chatState: ChatState(historyMessages: [pendingChild]),
        currentUserId: 'me',
        convForStatus: null,
        bubbleKeys: {},
        isTyping: false,
        isAgentBubble: false,
        menuController: _MockMenu(),
        multiSelectController: _MockMulti(),
        fileController: _MockFile(),
        jumpController: _MockJump(),
        ref: _MockRef(),
      );

      BuildContext? bc;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (c) {
          bc = c;
          return const SizedBox();
        }),
      ));

      final widget = ChatMessageItemBuilder.buildMessage(bc!, pendingChild, ctx);
      expect(widget, isA<SizedBox>());
    });

    testWidgets('终态子审批卡(approved) → SizedBox.shrink(不漏出完整行)', (tester) async {
      final approvedChild = _mkMsg(
        msgType: 'permission_card',
        status: 'approved',
        parentMsgId: 'task-card-1',
      );

      final ctx = ChatMessageItemBuildContext(
        chatState: ChatState(historyMessages: [approvedChild]),
        currentUserId: 'me',
        convForStatus: null,
        bubbleKeys: {},
        isTyping: false,
        isAgentBubble: false,
        menuController: _MockMenu(),
        multiSelectController: _MockMulti(),
        fileController: _MockFile(),
        jumpController: _MockJump(),
        ref: _MockRef(),
      );

      BuildContext? bc;
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (c) {
          bc = c;
          return const SizedBox();
        }),
      ));

      final widget = ChatMessageItemBuilder.buildMessage(bc!, approvedChild, ctx);
      expect(widget, isA<SizedBox>());
    });
  });

  group('ChatMessageX.isPendingChildApproval 谓词分类', () {
    test('pending permission_card + parent_msg_id 非空 → true', () {
      expect(
        _mkMsg(msgType: 'permission_card', status: 'pending', parentMsgId: 't1')
            .isPendingChildApproval,
        isTrue,
      );
    });

    test('pending question_card + parent_msg_id 非空 → true', () {
      expect(
        _mkMsg(msgType: 'question_card', status: 'pending', parentMsgId: 't1')
            .isPendingChildApproval,
        isTrue,
      );
    });

    test('主会话 pending 卡(parent_msg_id 为空) → false', () {
      expect(
        _mkMsg(msgType: 'permission_card', status: 'pending').isPendingChildApproval,
        isFalse,
      );
    });

    test('终态子审批卡(approved) → false', () {
      expect(
        _mkMsg(msgType: 'permission_card', status: 'approved', parentMsgId: 't1')
            .isPendingChildApproval,
        isFalse,
      );
    });

    test('普通子事件(reasoning) → false', () {
      expect(
        _mkMsg(msgType: 'reasoning', status: 'pending', parentMsgId: 't1')
            .isPendingChildApproval,
        isFalse,
      );
    });
  });

  group('ChatMessageX.isChildApprovalCard 谓词分类', () {
    test('pending 子审批卡 → true', () {
      expect(
        _mkMsg(msgType: 'permission_card', status: 'pending', parentMsgId: 't1')
            .isChildApprovalCard,
        isTrue,
      );
    });

    test('终态子审批卡(approved) → true', () {
      expect(
        _mkMsg(msgType: 'permission_card', status: 'approved', parentMsgId: 't1')
            .isChildApprovalCard,
        isTrue,
      );
    });

    test('终态子审批卡(denied) → true', () {
      expect(
        _mkMsg(msgType: 'question_card', status: 'denied', parentMsgId: 't1')
            .isChildApprovalCard,
        isTrue,
      );
    });

    test('主会话审批卡(parent_msg_id 为空) → false', () {
      expect(
        _mkMsg(msgType: 'permission_card', status: 'pending').isChildApprovalCard,
        isFalse,
      );
    });

    test('普通子事件(reasoning) → false', () {
      expect(
        _mkMsg(msgType: 'reasoning', status: 'pending', parentMsgId: 't1')
            .isChildApprovalCard,
        isFalse,
      );
    });
  });

  group('实时新消息入场展开动画(animateEntry)', () {
    late BuildContext bc;

    ChatMessageItemBuildContext _buildCtx() {
      final ref = _MockRef();
      // MessageRow 构造读 settingsProvider(baseUrl)/authProvider(token)。
      when(() => ref.read(settingsProvider)).thenReturn('');
      when(() => ref.read(authProvider)).thenReturn(AuthState(token: null));
      final multi = _MockMulti();
      when(() => multi.isSelectionMode).thenReturn(false);
      when(() => multi.isSelected(any())).thenReturn(false);
      return ChatMessageItemBuildContext(
        chatState: ChatState(historyMessages: const []),
        currentUserId: 'me',
        convForStatus: null,
        bubbleKeys: {},
        isTyping: false,
        isAgentBubble: false,
        menuController: _MockMenu(),
        multiSelectController: multi,
        fileController: _MockFile(),
        jumpController: _MockJump(),
        ref: ref,
      );
    }

    Future<void> pumpBc(WidgetTester tester) async {
      await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(builder: (c) {
          bc = c;
          return const SizedBox();
        }),
      ));
    }

    ChatMessage _reasoning(bool isStreaming) => ChatMessage(
          id: 's1',
          conversationId: 'c1',
          senderType: 'agent',
          senderId: 'a1',
          content: {'msg_type': 'reasoning', 'data': {'text': '思考中'}},
          isStreaming: isStreaming,
          createdAt: DateTime.parse('2026-07-15T10:00:00Z'),
        );

    testWidgets('卡片 + animateEntry=true → 包 EnterExpand 入场动画', (tester) async {
      await pumpBc(tester);
      final msg = _mkMsg(msgType: 'card', status: 'running');
      final w = ChatMessageItemBuilder.buildMessage(bc, msg, _buildCtx(),
          animateEntry: true);
      expect(w, isA<EnterExpand>());
    });

    testWidgets('卡片 + animateEntry=false(历史加载)→ 不包动画', (tester) async {
      await pumpBc(tester);
      final msg = _mkMsg(msgType: 'card', status: 'completed');
      final w = ChatMessageItemBuilder.buildMessage(bc, msg, _buildCtx());
      expect(w, isNot(isA<EnterExpand>()));
    });

    testWidgets('流式 reasoning + animateEntry=true → 包 EnterExpand', (tester) async {
      await pumpBc(tester);
      final w = ChatMessageItemBuilder.buildMessage(bc, _reasoning(true), _buildCtx(),
          animateEntry: true);
      expect(w, isA<EnterExpand>());
    });

    testWidgets('reasoning 终态替换(isStreaming=false)→ 不重播动画', (tester) async {
      await pumpBc(tester);
      final w = ChatMessageItemBuilder.buildMessage(bc, _reasoning(false), _buildCtx(),
          animateEntry: true);
      expect(w, isNot(isA<EnterExpand>()));
    });
  });
}
