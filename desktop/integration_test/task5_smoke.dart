// Task 5 手测 smoke:连 dev server(:18008) 真实 HTTP/WS 链路,
// 验证桌面聊天页消息列表 + core 渲染管线(手动 flutter drive 跑,不入 CI)。
// 前置:dev server 起 + desktop-m2 用户 + 种子会话(见 task-5 report)。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_desktop/pages/messages_page.dart';
import 'package:wanling_desktop/providers/selected_conv_provider.dart';
import 'package:wanling_desktop/theme/desktop_theme.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  const server = String.fromEnvironment('SMOKE_SERVER',
      defaultValue: 'http://localhost:18008');

  late ProviderContainer container;

  setUpAll(() async {
    // 对齐 desktop main.dart 启动序列:渲染注册表(否则消息走 UnknownRenderer)
    registerBuiltinRenderers();
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    // 直连 dev server(真实网络,不走 UI 设置)
    await container.read(settingsProvider.notifier).setBaseUrl(server);
  });

  testWidgets('登录→选中会话→历史渲染(text/markdown/聚合卡)→发消息→WS 回流',
      (tester) async {
    // 1. 真实登录(真 HTTP + TokenVault 持久化)
    await container
        .read(authProvider.notifier)
        .login('desktop-m2', 'm2test123456');
    expect(container.read(authProvider.select((s) => s.user)), isNotNull,
        reason: '登录失败:user 为空');
    debugPrint('[smoke] login OK: ${container.read(authProvider).user!.username}');

    // 2. pump 消息页(登录态由 provider watch 驱动,无需 router)
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: DesktopTheme.light,
          home: const MessagesPage(),
        ),
      ),
    );

    // 3. 等会话列表加载(真 HTTP ListForUser;截 10s)
    final convs = await _until(
      () => container.read(conversationProvider),
      (list) => list.isNotEmpty,
      const Duration(seconds: 10),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    debugPrint('[smoke] conversations: ${convs.map((c) => '${c.id}:${c.displayName}')}');
    expect(convs, isNotEmpty, reason: '会话列表为空');
    final conv = convs.first;

    // 4. 选中会话 → ChatView 挂载 → chatProvider 真实拉取
    container.read(selectedConvProvider.notifier).state = conv.id;
    final chatKey = (convId: conv.id, agentId: conv.agent?.id);
    // autoDispose family:listen 建立持续订阅保活(read 轮询会建短命实例,
    // 其 _initialize 在 dispose 后写 state 抛错)。
    final chatSub = container.listen(chatProvider(chatKey), (_, _) {});
    addTearDown(chatSub.close);
    final chatInit = await _until(
      () => container.read(chatProvider(chatKey)),
      (s) => s.isServerInitialized && s.displayMessages.isNotEmpty,
      const Duration(seconds: 10),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    debugPrint('[smoke] chat loaded: ${chatInit.displayMessages.length} msgs, '
        'title=${chatInit.convTitle}, git=${chatInit.sessionMeta?.gitBranch}');

    // 5. 渲染断言:标题 + git 徽标(进会话自动贴底,最新消息在视口内)
    expect(find.text(chatInit.convTitle ?? conv.displayName), findsWidgets);
    expect(find.textContaining('develop-v1.5.0'), findsOneWidget,
        reason: 'git 分支徽标未渲染');
    expect(find.textContaining('core 渲染管线'), findsWidgets,
        reason: 'agent markdown 气泡未渲染');
    // 聚合卡元素(markdown 元素正文)
    expect(find.textContaining('聚合卡元素:reasoning'), findsWidgets,
        reason: '聚合卡 markdown 元素未渲染');
    // 防回归:UnknownRenderer 会把 content 整体 toString(含 'msg_type'),
    // 出现即说明 renderer 注册缺失、断言(上)是 false positive。
    expect(find.textContaining('msg_type'), findsNothing,
        reason: '消息走了 UnknownRenderer(renderer 注册缺失)');
    // 聚合卡 reasoning 元素折叠态文案(卡片顶部,贴底后可能在视口外,上滚 400px)
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 400));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.textContaining('思考完成'), findsWidgets,
        reason: '聚合卡 reasoning 元素折叠头未渲染');

    // 6. 聚合卡「展开」:tap reasoning 折叠头 → 全文页出现
    await tester.tap(find.textContaining('思考完成').first);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.textContaining('用户发来手测消息'), findsOneWidget,
        reason: 'reasoning 全文页未打开(聚合卡展开失败)');
    debugPrint('[smoke] aggregate reasoning expanded OK');
    // bottom sheet 用 ESC 关闭(pageBack 可能误 pop home 路由)
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.byType(MessagesPage), findsOneWidget, reason: 'sheet 关闭后主页面丢失');
    expect(find.textContaining('用户发来手测消息'), findsNothing,
        reason: 'reasoning 全文 sheet 未关闭');

    // 7. 滚到顶断言最老消息(user text 气泡,贴底进会话时在视口外)
    await tester.scrollUntilVisible(
      find.text('你好,这是桌面端手测消息'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('你好,这是桌面端手测消息'), findsOneWidget,
        reason: 'user text 气泡未渲染');
    debugPrint('[smoke] oldest user bubble visible after scroll-top');

    // 8. 发消息(真 HTTP send + 乐观更新 + WS echo 回流),滚回底断言
    await container.read(chatProvider(chatKey).notifier).sendText('桌面端回复:渲染管线 OK');
    await _until(
      () => container.read(chatProvider(chatKey)),
      (s) => s.displayMessages
          .any((m) => (m.content['data']?['text'] ?? '').contains('桌面端回复')),
      const Duration(seconds: 10),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    // 新消息在列表底部:定量 drag 贴底(scrollUntilVisible 会被多匹配卡住)
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -2000));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('桌面端回复:渲染管线 OK'), findsWidgets,
        reason: '发送消息气泡未渲染(乐观/echo)');

    debugPrint('[smoke] ALL PASS');
  });
}

/// 轮询直到 condition 为真或超时(fail fast 抛错)。
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
