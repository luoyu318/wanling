import 'package:app/models/message.dart';
import 'package:app/providers/chat_state.dart';
import 'package:app/widgets/chat/multi_select_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造一个最小可用的 [MultiSelectContext],onSetState 默认同步执行回调,
/// ref/getContext 默认抛错(测试用 overrides 替换需要的字段)。
MultiSelectContext _buildContext({
  BuildContext Function()? getContext,
  WidgetRef? ref,
  ({String convId, String? agentId})? chatKey,
  void Function(VoidCallback)? onSetState,
}) {
  return MultiSelectContext(
    getContext: getContext ?? (() => throw UnimplementedError()),
    ref: ref ?? _DummyRef(),
    chatKey: chatKey ?? (convId: 'c1', agentId: null),
    onSetState: onSetState ?? ((f) => f()),
  );
}

ChatMessage _textMsg({
  required String id,
  String text = 'hi',
  String senderId = 'me',
  DateTime? createdAt,
}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: 'user',
    senderId: senderId,
    content: {'msg_type': 'text', 'data': {'text': text}},
    createdAt: createdAt ?? DateTime.now(),
    status: MessageStatus.sent,
  );
}

ChatMessage _imageMsg({required String id}) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: 'user',
    senderId: 'me',
    content: {'msg_type': 'image', 'data': {'url': 'https://x/a.png'}},
    createdAt: DateTime.now(),
    status: MessageStatus.sent,
  );
}

/// 占位 [WidgetRef]:测试中不触发 ref.read/write 时使用,noSuchMethod 默认抛错。
class _DummyRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 可编程 [WidgetRef]:read(chatProvider(key)) 返回预设 [ChatState]。
/// 其他调用走 noSuchMethod 抛错(测试若误触达会立刻暴露)。
class _StubRef implements WidgetRef {
  _StubRef(this.chatState);
  final ChatState chatState;

  @override
  T read<T>(ProviderListenable<T> provider) {
    if (T == ChatState) return chatState as T;
    throw UnimplementedError('Unexpected read for type $T');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Clipboard 调用捕获器(可变,handler 内写入,测试外读取)。
class _ClipboardProbe {
  bool wasCalled = false;
  String? copiedText;
}

/// 注册 Clipboard mock,返回可读写的 probe + cleanup 函数。
({_ClipboardProbe probe, void Function() cleanup}) _mockClipboard(
    TestDefaultBinaryMessenger messenger) {
  final probe = _ClipboardProbe();
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') {
      probe.wasCalled = true;
      probe.copiedText = (call.arguments as Map)['text'] as String;
    }
    return null;
  });
  return (
    probe: probe,
    cleanup: () =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

/// pump 一个最小 MaterialApp 拿 BuildContext,供 controller 的 snackbar / Clipboard 测试。
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
  group('初始状态', () {
    test('新构造的 controller selectedCount=0', () {
      final ctrl = MultiSelectController(_buildContext());
      expect(ctrl.selectedCount, 0);
    });

    test('新构造的 controller isSelectionMode=false', () {
      final ctrl = MultiSelectController(_buildContext());
      expect(ctrl.isSelectionMode, isFalse);
    });

    test('isSelected 未选 id → false', () {
      final ctrl = MultiSelectController(_buildContext());
      expect(ctrl.isSelected('m1'), isFalse);
    });

    test('selectedIdsList 初始为空副本', () {
      final ctrl = MultiSelectController(_buildContext());
      expect(ctrl.selectedIdsList, isEmpty);
    });
  });

  group('enterSelection', () {
    test('进入多选:isSelectionMode=true + isSelected(msgId)=true + selectedCount=1', () {
      final ctrl = MultiSelectController(_buildContext());
      ctrl.enterSelection('m1');
      expect(ctrl.isSelectionMode, isTrue);
      expect(ctrl.isSelected('m1'), isTrue);
      expect(ctrl.selectedCount, 1);
    });

    test('enterSelection 清旧选中再预选(二次进入只保留新 id)', () {
      final ctrl = MultiSelectController(_buildContext());
      ctrl.enterSelection('m1');
      ctrl.toggleSelect('m2');
      expect(ctrl.selectedCount, 2);
      ctrl.enterSelection('m3');
      expect(ctrl.isSelected('m1'), isFalse);
      expect(ctrl.isSelected('m2'), isFalse);
      expect(ctrl.isSelected('m3'), isTrue);
      expect(ctrl.selectedCount, 1);
    });

    test('enterSelection 调 onSetState(回调同步执行)', () {
      var setStateCalls = 0;
      final ctrl = MultiSelectController(
        _buildContext(onSetState: (f) {
          setStateCalls++;
          f();
        }),
      );
      ctrl.enterSelection('m1');
      expect(setStateCalls, 1);
    });
  });

  group('exitSelection', () {
    test('从多选态退出:isSelectionMode=false + selectedCount=0', () {
      final ctrl = MultiSelectController(_buildContext());
      ctrl.enterSelection('m1');
      ctrl.toggleSelect('m2');
      expect(ctrl.selectedCount, 2);
      ctrl.exitSelection();
      expect(ctrl.isSelectionMode, isFalse);
      expect(ctrl.selectedCount, 0);
      expect(ctrl.isSelected('m1'), isFalse);
    });

    test('exitSelection 调 onSetState', () {
      var setStateCalls = 0;
      final ctrl = MultiSelectController(
        _buildContext(onSetState: (f) {
          setStateCalls++;
          f();
        }),
      );
      ctrl.exitSelection();
      expect(setStateCalls, 1);
    });

    test('非多选态 exitSelection 也安全(不抛)', () {
      final ctrl = MultiSelectController(_buildContext());
      ctrl.exitSelection();
      expect(ctrl.isSelectionMode, isFalse);
      expect(ctrl.selectedCount, 0);
    });
  });

  group('toggleSelect', () {
    test('加:isSelected(id)=true + selectedCount=1', () {
      final ctrl = MultiSelectController(_buildContext());
      ctrl.toggleSelect('m1');
      expect(ctrl.isSelected('m1'), isTrue);
      expect(ctrl.selectedCount, 1);
    });

    test('切(已有 → 移除):isSelected(id)=false + selectedCount=0', () {
      final ctrl = MultiSelectController(_buildContext());
      ctrl.toggleSelect('m1');
      ctrl.toggleSelect('m1');
      expect(ctrl.isSelected('m1'), isFalse);
      expect(ctrl.selectedCount, 0);
    });

    test('幂等(加再切):回到未选', () {
      final ctrl = MultiSelectController(_buildContext());
      ctrl.toggleSelect('m1');
      expect(ctrl.selectedCount, 1);
      ctrl.toggleSelect('m1');
      expect(ctrl.selectedCount, 0);
      expect(ctrl.isSelected('m1'), isFalse);
    });

    test('多条消息独立勾选', () {
      final ctrl = MultiSelectController(_buildContext());
      ctrl.toggleSelect('m1');
      ctrl.toggleSelect('m2');
      ctrl.toggleSelect('m3');
      expect(ctrl.selectedCount, 3);
      // 只移除 m2,m1/m3 不受影响
      ctrl.toggleSelect('m2');
      expect(ctrl.selectedCount, 2);
      expect(ctrl.isSelected('m1'), isTrue);
      expect(ctrl.isSelected('m2'), isFalse);
      expect(ctrl.isSelected('m3'), isTrue);
    });
  });

  group('selectedIdsList', () {
    test('含选中 id / 顺序无关 / 副本不影响 controller 内部', () {
      final ctrl = MultiSelectController(_buildContext());
      ctrl.toggleSelect('m1');
      ctrl.toggleSelect('m2');
      final list = ctrl.selectedIdsList;
      expect(list, containsAll(['m1', 'm2']));
      expect(list.length, 2);
      // 破坏返回的副本
      list.clear();
      // controller 内部不受影响(证明返回的是副本而非内部引用)
      expect(ctrl.selectedCount, 2);
      expect(ctrl.isSelected('m1'), isTrue);
      expect(ctrl.isSelected('m2'), isTrue);
    });
  });

  group('batchCopy', () {
    testWidgets('空选中 → no-op(不读 ref / 不需要 BuildContext / 不调 Clipboard)',
        (tester) async {
      final mock = _mockClipboard(tester.binding.defaultBinaryMessenger);
      try {
        // 默认 getContext/ref 都会抛错,验证 batchCopy 早返不触达
        final ctrl = MultiSelectController(_buildContext());
        await ctrl.batchCopy();
        expect(mock.probe.wasCalled, isFalse, reason: '空选中不应调 Clipboard');
      } finally {
        mock.cleanup();
      }
    });

    testWidgets('有选中 → 拼接文本调 Clipboard.setData', (tester) async {
      final mock = _mockClipboard(tester.binding.defaultBinaryMessenger);

      final capturedCtx = await _pumpMinimalContext(tester);

      try {
        final ref = _StubRef(ChatState(historyMessages: [
          // createdAt 降序(newest-first,匹配 displayMessages 显示约定)
          _textMsg(id: 'm1', text: 'hello', createdAt: DateTime.parse('2026-07-03T00:00:00Z')),
          _textMsg(id: 'm2', text: 'world', createdAt: DateTime.parse('2026-07-02T00:00:00Z')),
          _textMsg(id: 'm3', text: 'ignored', createdAt: DateTime.parse('2026-07-01T00:00:00Z')), // 未选,不应出现
        ]));
        final ctrl = MultiSelectController(_buildContext(
          getContext: () => capturedCtx,
          ref: ref,
        ));
        ctrl.toggleSelect('m1');
        ctrl.toggleSelect('m2');
        await ctrl.batchCopy();
        expect(mock.probe.copiedText, 'hello\nworld');
        expect(mock.probe.wasCalled, isTrue);
      } finally {
        mock.cleanup();
      }
    });

    testWidgets('全图片(无文本)→ 提示「无可复制文本」不调 Clipboard', (tester) async {
      final mock = _mockClipboard(tester.binding.defaultBinaryMessenger);

      final capturedCtx = await _pumpMinimalContext(tester);

      try {
        final ref = _StubRef(ChatState(historyMessages: [
          _imageMsg(id: 'm1'),
          _imageMsg(id: 'm2'),
        ]));
        final ctrl = MultiSelectController(_buildContext(
          getContext: () => capturedCtx,
          ref: ref,
        ));
        ctrl.toggleSelect('m1');
        ctrl.toggleSelect('m2');
        await ctrl.batchCopy();
        // 等待 snackbar overlay 渲染
        await tester.pump();
        expect(mock.probe.wasCalled, isFalse, reason: '全图片不应调 Clipboard');
        expect(find.text('选中的消息无可复制文本'), findsOneWidget);
      } finally {
        mock.cleanup();
      }
    });
  });
}
