// Task 6 手测 smoke:连 dev server(:18008) 真实 HTTP/WS 链路,
// 验证桌面输入区(slash 面板 + Enter/Shift+Enter + mention 面板 + 真发文件/图片)。
// 手动 flutter drive 跑,不入 CI。前置:
// - dev server 起 + desktop-m2 用户 + dm_user_agent 种子会话(T5 种子)
// - M2 手测助手 agent 的 slash catalog 非空(第二 plugin 实例上报,见 task-6 report)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/local_message_store_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart'
    show sharedPrefsProvider;
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_desktop/pages/messages_page.dart';
import 'package:wanling_desktop/providers/selected_conv_provider.dart';
import 'package:wanling_desktop/theme/desktop_theme.dart';
import 'package:wanling_core/widgets/image_thumb.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  const server = String.fromEnvironment('SMOKE_SERVER',
      defaultValue: 'http://localhost:18008');

  late ProviderContainer container;

  setUpAll(() async {
    registerBuiltinRenderers();
    // libsecret keyring 在 headless dbus 会话未解锁,TokenVault 读写会弹
    // SystemPrompter 挂死;测试用内存实现旁路(flutter_secure_storage 官方口)。
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    await container.read(settingsProvider.notifier).setBaseUrl(server);
  });

  testWidgets('输入区:slash 面板(catalog 53 条)+ Enter 发送 + Shift+Enter 换行 + sendSlash + 真发文件/图片',
      (tester) async {
    // 1. 登录 + 会话列表 + 选会话(真实 HTTP)
    await container
        .read(authProvider.notifier)
        .login('desktop-m2', 'm2test123456');
    expect(container.read(authProvider.select((s) => s.user)), isNotNull,
        reason: '登录失败');
    debugPrint('[smoke] login OK');

    // 对齐生产时序:listen 保活(autoDispose)+ 等 store ready 再挂页。
    // chatProvider watch store 的 valueOrNull,null→实例会重建 ChatNotifier,
    // 首个实例 _initialize 若在异步跑,dispose 后写 state 抛 Bad state
    // (core 已知边界,见 chat_provider.dart:1732 注释)。
    final storeSub = container.listen(localMessageStoreProvider, (_, _) {});
    addTearDown(storeSub.close);
    await container.read(localMessageStoreProvider.future);
    debugPrint('[smoke] local store ready');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: DesktopTheme.light,
          home: const MessagesPage(),
        ),
      ),
    );
    final convs = await _until(
      () => container.read(conversationProvider),
      (list) => list.isNotEmpty,
      const Duration(seconds: 10),
    );
    final conv = convs.firstWhere((c) => c.type == 'dm_user_agent',
        orElse: () => convs.first);
    debugPrint('[smoke] conv: ${conv.id} ${conv.displayName} agent=${conv.agent?.id}');

    container.read(selectedConvProvider.notifier).state = conv.id;
    final chatKey = (convId: conv.id, agentId: conv.agent?.id);
    final chatSub = container.listen(chatProvider(chatKey), (_, _) {});
    addTearDown(chatSub.close);
    await _until(
      () => container.read(chatProvider(chatKey)),
      (s) => s.isServerInitialized,
      const Duration(seconds: 10),
    );
    await tester.pump(const Duration(seconds: 1));

    // 2. 输入区渲染:工具栏 4 按钮 + 输入框
    expect(find.byKey(const ValueKey('input_toolbar_file')), findsOneWidget);
    expect(find.byKey(const ValueKey('input_toolbar_image')), findsOneWidget);
    expect(find.byKey(const ValueKey('input_toolbar_slash')), findsOneWidget);
    expect(find.byKey(const ValueKey('input_toolbar_mention')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('desktop_input_field')), findsOneWidget);

    // 等 slash catalog 真实拉取完成(斜杠按钮由 catalog 非空启用)
    final field = find.byKey(const ValueKey('desktop_input_field'));
    await tester.tap(field);
    await tester.pump(const Duration(seconds: 1));

    // 3. slash 面板:输入 / 弹出(真实 catalog),过滤 /rev 只剩 review 相关
    await tester.enterText(field, '/');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('slash_panel')), findsOneWidget,
        reason: '输入 / 未弹出 slash 面板(catalog 空或触发失败)');
    final panelItems = find.byKey(const ValueKey('slash_panel'));
    debugPrint('[smoke] slash panel open, items=${panelItems.evaluate().length}');

    await tester.enterText(field, '/rev');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('slash_panel_item_review')),
        findsOneWidget, reason: '过滤 /rev 后 review 命令不可见');
    expect(find.byKey(const ValueKey('slash_panel_item_init')), findsNothing,
        reason: '过滤 /rev 后 init 仍可见(过滤失效)');

    // 4. ↑↓ 导航 + Enter 选中 → chip → args + Enter → sendSlash 真发送
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('slash_chip')), findsOneWidget,
        reason: '面板 Enter 选中后 slash chip 未出现');
    debugPrint('[smoke] slash chip OK');

    final slashStamp = 'develop-v1.5.0-${DateTime.now().millisecondsSinceEpoch}';
    await tester.enterText(field, slashStamp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(seconds: 1));
    final slashState = await _until(
      () => container.read(chatProvider(chatKey)),
      // displayMessages newest-first:取最新一条 slash_echo(历史可能残留旧命令)
      (s) => s.displayMessages.any((m) =>
          !m.id.startsWith('local_') &&
          m.content['msg_type'] == 'slash_echo' &&
          ((m.content['data']['display'] ?? '') as String).contains(slashStamp)),
      const Duration(seconds: 10),
    );
    final echo = slashState.displayMessages
        .firstWhere((m) =>
            m.content['msg_type'] == 'slash_echo' &&
            ((m.content['data']['display'] ?? '') as String).contains(slashStamp))
        .content['data']['display'] as String;
    debugPrint('[smoke] sendSlash OK: display=$echo');
    expect(echo, contains('review'),
        reason: 'slashEcho display 不含命令名');

    // 5. Shift+Enter 换行:文本变 he\n(不发送)
    await tester.enterText(field, 'he');
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(
      // 精确到输入框内的 EditableText(agent 流式回复渲染树里也可能有别的)
      tester
          .widget<EditableText>(find.descendant(
              of: field, matching: find.byType(EditableText)))
          .controller
          .text,
      'he\n',
      reason: 'Shift+Enter 未产生换行',
    );

    // 6. Enter 发送多行文本(真 HTTP + WS echo 回流)
    await tester.enterText(field, 'he\nwo');
    await tester.pump();
    final before = container.read(chatProvider(chatKey)).displayMessages.length;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(seconds: 1));
    final afterText = await _until(
      () => container.read(chatProvider(chatKey)),
      (s) => s.displayMessages.any((m) =>
          !m.id.startsWith('local_') &&
          (m.content['data']?['text'] ?? '') == 'he\nwo'),
      const Duration(seconds: 10),
    );
    expect(afterText.displayMessages.length, greaterThan(before));
    debugPrint('[smoke] Enter sendText OK(server echo replaced local)');

    // 7. mention 面板:@ 弹出(dm_user_agent 会话 2 participants)
    await tester.enterText(field, '@');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('mention_panel')), findsOneWidget,
        reason: '输入 @ 未弹出提及面板');
    debugPrint('[smoke] mention panel OK');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('mention_panel')), findsNothing);

    // 8. 真发文件:临时文件 → uploadFile(真 HTTP) → sendFile → file 消息渲染
    final tmp = File('/tmp/opencode/task6_upload.txt')
      ..writeAsStringSync('task6 desktop smoke file ${DateTime.now()}');
    final api = container.read(apiProvider);
    final fileId =
        await api.uploadFile(tmp.path, convId: conv.id);
    await container.read(chatProvider(chatKey).notifier).sendFile(
          fileId,
          MsgType.file,
          filename: 'task6_upload.txt',
          mimeType: 'text/plain',
          fileSize: tmp.lengthSync(),
        );
    await _until(
      () => container.read(chatProvider(chatKey)),
      (s) => s.displayMessages.any((m) =>
          !m.id.startsWith('local_') &&
          m.content['msg_type'] == 'file' &&
          (m.content['data']?['filename'] ?? '') == 'task6_upload.txt'),
      const Duration(seconds: 10),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('task6_upload.txt'), findsWidgets,
        reason: 'file 消息 FileCard 未渲染文件名');
    debugPrint('[smoke] real file upload+send+render OK');

    // 9. 真发图片:1x1 PNG → sendFile(image) → ImageThumb 渲染
    final png = File('/tmp/opencode/task6_pixel.png')
      ..writeAsBytesSync(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49,
        0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1F, 0x15,
        0xC4, 0x89, 0, 0, 0, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62,
        0, 1, 0, 0, 5, 0, 1, 0x0D, 0x0A, 0x2D, 0xB4, 0, 0, 0, 0, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ]);
    final imgId = await api.uploadFile(png.path, convId: conv.id);
    await container.read(chatProvider(chatKey).notifier).sendFile(
          imgId,
          MsgType.image,
          filename: 'task6_pixel.png',
          mimeType: 'image/png',
          fileSize: png.lengthSync(),
        );
    await _until(
      () => container.read(chatProvider(chatKey)),
      (s) => s.displayMessages.any((m) =>
          !m.id.startsWith('local_') &&
          m.content['msg_type'] == 'image'),
      const Duration(seconds: 10),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ImageThumb), findsWidgets,
        reason: 'image 消息 ImageThumb 未渲染');
    debugPrint('[smoke] real image upload+send+render OK');

    debugPrint('[smoke] ALL PASS');
  });
}

Future<T> _until<T>(
  T Function() read,
  bool Function(T) condition,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  T v = read();
  while (!condition(v)) {
    if (DateTime.now().isAfter(deadline)) {
      throw 'timeout waiting condition, last=$v';
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    v = read();
  }
  return v;
}
