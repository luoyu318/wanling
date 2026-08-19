// desktop/test/input_bar_test.dart
// Task 6:桌面输入区(工具栏上置 + slash 面板 + @ 提及 + 文件图片)。
// 策略:chatProvider override 成 _RecNotifier(覆写 sendText/sendSlash/sendFile
// 只记录不发网络,构造期 init 走 _StubApi 内存数据),apiProvider override 成
// _StubApi(catalog/participants/upload 内存返回),file_picker 经构造注入 fake。
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/models/participant.dart';
import 'package:wanling_core/models/slash_command.dart';
import 'package:wanling_core/models/unread_info.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_desktop/widgets/chat/desktop_input_bar.dart';

/// stub ApiService:chat init / participants / slash catalog / upload 全内存返回。
class _StubApi extends ApiService {
  _StubApi({this.catalog = const [], this.participants = const []})
      : super(baseUrl: '');

  final List<SlashCommand> catalog;
  final List<Participant> participants;

  /// uploadFile 调用记录:(path, convId)。
  final uploaded = <(String, String?)>[];

  @override
  Future<Conversation> getConversation(String convId) async => Conversation(
        id: convId,
        type: 'agent_session',
        title: '测试会话',
        participants: participants,
        lastMessageContent: null,
        lastMessageAt: DateTime(2026, 1, 1),
        createdAt: DateTime(2026, 1, 1),
      );

  @override
  Future<UnreadInfo> getUnreadInfo(String convId) async =>
      const UnreadInfo(unreadCount: 0);

  @override
  Future<List<ChatMessage>> getMessagesBefore(
    String conversationId, {
    DateTime? before,
    int limit = 20,
  }) async => [];

  @override
  Future<List<SlashCommand>> getAgentSlashCatalog(String agentId) async =>
      catalog;

  @override
  Future<String> uploadFile(String filePath, {String? convId}) async {
    uploaded.add((filePath, convId));
    return 'file-id-1';
  }
}

/// 种子 auth:登录态 user(u1)+token(对齐 T5 测试做法)。
class _StubAuth extends AuthNotifier {
  _StubAuth() : super(ApiService(baseUrl: '')) {
    state = AuthState(
      user: User(id: 'u1', username: 'tester', createdAt: DateTime(2026, 1, 1)),
      token: 'test-token',
    );
  }
}

/// 记录型 ChatNotifier:三个 send 全部覆写为记录,不发网络。
/// super 构造的 _initialize/_listenWS 走 _StubApi + 空 WebSocketService(T5 同款)。
class _RecNotifier extends ChatNotifier {
  _RecNotifier(ApiService api, String convId, String? agentId)
      : super(api, WebSocketService(), convId, agentId, 'u1');

  final texts = <String>[];
  final slashes = <(String, String)>[]; // (name, args)
  final files = <(String, MsgType)>[]; // (fileId, msgType)

  @override
  Future<void> sendText(String text) async => texts.add(text);

  @override
  Future<void> sendSlash(String name, String args) async =>
      slashes.add((name, args));

  @override
  Future<void> sendFile(String fileId, MsgType msgType,
      {String filename = '', String mimeType = '', int fileSize = 0}) async {
    files.add((fileId, msgType));
  }
}

class _Bar {
  final _RecNotifier notifier;
  final _StubApi api;
  const _Bar(this.notifier, this.api);
}

Future<_Bar> _pumpBar(
  WidgetTester tester, {
  String? agentId = 'agent-1',
  List<SlashCommand> catalog = const [],
  List<Participant> participants = const [],
  Future<FilePickerResult?> Function(FileType type)? picker,
}) async {
  final api = _StubApi(catalog: catalog, participants: participants);
  final notifier = _RecNotifier(api, 'conv-1', agentId);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      authProvider.overrideWith((ref) => _StubAuth()),
      chatProvider.overrideWith((ref, key) => notifier),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: DesktopInputBar(
            convId: 'conv-1',
            agentId: agentId,
            filePicker: picker,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Bar(notifier, api);
}

final _field = find.byKey(const ValueKey('desktop_input_field'));

String _fieldText(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText)).controller.text;

Future<void> _focusAndEnterText(WidgetTester tester, String text) async {
  await tester.tap(_field);
  await tester.pump();
  await tester.enterText(_field, text);
  await tester.pump();
}

List<SlashCommand> _catalog() => const [
      SlashCommand(
          name: 'compact',
          template: '',
          description: '压缩上下文',
          source: 'command'),
      SlashCommand(
          name: 'model', template: '', description: '切换模型', source: 'command'),
      SlashCommand(
          name: 'help', template: '', description: '帮助', source: 'skill'),
    ];

List<Participant> _participants() => [
      Participant(
          memberId: 'u2',
          memberType: 'user',
          role: 'member',
          username: 'alice',
          nickname: '成员甲',
          avatarUrl: ''),
      Participant(
          memberId: 'ag1',
          memberType: 'agent',
          role: 'member',
          username: '万灵助手',
          nickname: '',
          avatarUrl: ''),
    ];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('输入 he + Enter 发送 sendText 并清空输入框', (tester) async {
    final bar = await _pumpBar(tester);
    await _focusAndEnterText(tester, 'he');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(bar.notifier.texts, ['he']);
    expect(_fieldText(tester), '');
  });

  testWidgets('Shift+Enter 产生换行不发送,Enter 才发送', (tester) async {
    final bar = await _pumpBar(tester);
    await _focusAndEnterText(tester, 'he');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(_fieldText(tester), 'he\n');
    expect(bar.notifier.texts, isEmpty);

    // 追加一行后 Enter:整段多行文本一次发出
    await tester.enterText(_field, 'he\nwo');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(bar.notifier.texts, ['he\nwo']);
  });

  testWidgets('输入 / 弹出 slash 面板,query 过滤,Escape 关闭', (tester) async {
    await _pumpBar(tester, catalog: _catalog());
    await _focusAndEnterText(tester, '/');

    expect(find.byKey(const ValueKey('slash_panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('slash_panel_item_compact')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('slash_panel_item_model')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('slash_panel_item_help')), findsOneWidget);

    // 过滤:/mod 只剩 model
    await tester.enterText(_field, '/mod');
    await tester.pump();
    expect(find.byKey(const ValueKey('slash_panel_item_model')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('slash_panel_item_compact')),
        findsNothing);

    // Escape 关闭
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(const ValueKey('slash_panel')), findsNothing);
  });

  testWidgets('输入 @ 弹出提及面板,过滤 + 点击成员填入 @昵称', (tester) async {
    await _pumpBar(tester, participants: _participants());
    await _focusAndEnterText(tester, '@');

    expect(find.byKey(const ValueKey('mention_panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('mention_panel_item_u2')), findsOneWidget);
    expect(find.byKey(const ValueKey('mention_panel_item_ag1')),
        findsOneWidget);

    // 过滤:@成员 只剩 成员甲
    await tester.enterText(_field, '@成员');
    await tester.pump();
    expect(find.byKey(const ValueKey('mention_panel_item_u2')), findsOneWidget);
    expect(find.byKey(const ValueKey('mention_panel_item_ag1')), findsNothing);

    // 点击选中:替换触发词为 @昵称 + 空格,面板关闭
    await tester.tap(find.text('成员甲'));
    await tester.pump();
    expect(_fieldText(tester), '@成员甲 ');
    expect(find.byKey(const ValueKey('mention_panel')), findsNothing);
  });

  testWidgets('slash 面板 Enter 选中填标签,输 args 后 Enter 走 sendSlash',
      (tester) async {
    final bar = await _pumpBar(tester, catalog: _catalog());
    await _focusAndEnterText(tester, '/mod');

    // 面板开时 Enter = 选中高亮项(model),填入标签 chip
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.byKey(const ValueKey('slash_chip')), findsOneWidget);
    expect(find.text('/model'), findsOneWidget);
    expect(find.byKey(const ValueKey('slash_panel')), findsNothing);

    // 输 args 再 Enter:sendSlash(name, args) + chip 清除
    await tester.enterText(_field, 'glm-5');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(bar.notifier.slashes, [('model', 'glm-5')]);
    expect(bar.notifier.texts, isEmpty);
    expect(find.byKey(const ValueKey('slash_chip')), findsNothing);
  });

  testWidgets('slash 面板 arrowDown 移动高亮后 Enter 选中第二项', (tester) async {
    await _pumpBar(tester, catalog: _catalog());
    await _focusAndEnterText(tester, '/');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(find.byKey(const ValueKey('slash_chip')), findsOneWidget);
    expect(find.text('/model'), findsOneWidget);
  });

  testWidgets('📎 选文件:uploadFile(带 convId) → sendFile(file 消息)',
      (tester) async {
    Future<FilePickerResult?> picker(FileType type) async =>
        FilePickerResult(
          [PlatformFile(name: 'doc.pdf', size: 100, path: '/tmp/doc.pdf')],
        );
    final bar = await _pumpBar(tester, picker: picker);

    await tester.tap(find.byKey(const ValueKey('input_toolbar_file')));
    await tester.pumpAndSettle();

    expect(bar.api.uploaded, [('/tmp/doc.pdf', 'conv-1')]);
    expect(bar.notifier.files, [('file-id-1', MsgType.file)]);
  });

  testWidgets('🖼️ 选图片:png 扩展名 → sendFile(image 消息)', (tester) async {
    Future<FilePickerResult?> picker(FileType type) async =>
        FilePickerResult(
          [PlatformFile(name: 'photo.png', size: 50, path: '/tmp/photo.png')],
        );
    final bar = await _pumpBar(tester, picker: picker);

    await tester.tap(find.byKey(const ValueKey('input_toolbar_image')));
    await tester.pumpAndSettle();

    expect(bar.notifier.files, [('file-id-1', MsgType.image)]);
  });

  testWidgets('agentId 为 null 时斜杠按钮禁用(点击不插入触发字符)',
      (tester) async {
    await _pumpBar(tester, agentId: null, catalog: _catalog());
    await _focusAndEnterText(tester, '');

    await tester.tap(find.byKey(const ValueKey('input_toolbar_slash')));
    await tester.pump();
    expect(_fieldText(tester), '');
    expect(find.byKey(const ValueKey('slash_panel')), findsNothing);
  });

  testWidgets('工具栏 / 按钮插入触发字符并弹面板', (tester) async {
    await _pumpBar(tester, catalog: _catalog());
    await _focusAndEnterText(tester, '');

    await tester.tap(find.byKey(const ValueKey('input_toolbar_slash')));
    await tester.pump();
    expect(_fieldText(tester), '/');
    expect(find.byKey(const ValueKey('slash_panel')), findsOneWidget);
  });
}
