// Task 7 手测 smoke:连 dev server(:18008) 真实 HTTP/WS/RPC 链路,
// 验证详情侧栏(信息 tab 会话信息 + 变更 tab 真实 session.diff RPC +
// binary/truncated 防护消费端渲染)。
// 手动 flutter drive 跑,不入 CI。前置(见 task-7-report):
// - dev server 起 + desktop-m2 用户 + dm 种子会话(T5 种子)
// - m2 隔离 plugin 实例(WANLING_DEFAULT_DIRECTORY=/tmp/opencode/t7_git)
//   已锚定 OC session,仓库含 tracked modified + untracked 大文本(>256KB
//   → truncated)+ untracked 二进制(→ binary)三类变更
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/local_message_store_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart'
    show sharedPrefsProvider;
import 'package:wanling_core/providers/session_diff_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_desktop/pages/messages_page.dart';
import 'package:wanling_desktop/providers/selected_conv_provider.dart';
import 'package:wanling_desktop/theme/desktop_theme.dart';
import 'package:wanling_desktop/widgets/detail_panel.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  const server = String.fromEnvironment('SMOKE_SERVER',
      defaultValue: 'http://localhost:18008');

  late ProviderContainer container;

  setUpAll(() async {
    registerBuiltinRenderers();
    // libsecret keyring 在 headless dbus 会话未解锁,TokenVault 读写会挂死
    // (T5/T6 同款旁路)
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
    );
    await container.read(settingsProvider.notifier).setBaseUrl(server);
  });

  testWidgets('详情侧栏:信息 tab 会话信息 + 变更 tab 真实 session.diff(3 类文件防护)', (tester) async {
    // 1. 登录 + 选 dm 会话(真实 HTTP)
    await container
        .read(authProvider.notifier)
        .login('desktop-m2', 'm2test123456');
    expect(container.read(authProvider.select((s) => s.user)), isNotNull,
        reason: '登录失败');
    debugPrint('[smoke] login OK');

    // 对齐生产时序:store 保活 + ready 再挂页(T5 陷阱)
    final storeSub = container.listen(localMessageStoreProvider, (_, _) {});
    addTearDown(storeSub.close);
    await container.read(localMessageStoreProvider.future);

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
      timeout: const Duration(seconds: 10),
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
      timeout: const Duration(seconds: 10),
    );
    await tester.pump(const Duration(seconds: 1));

    // 2. 打开详情面板:信息 tab 默认(会话名 + 成员)
    expect(find.byType(DetailPanel), findsNothing);
    await tester.tap(find.byTooltip('详情'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DetailPanel), findsOneWidget, reason: '详情面板未展开');
    expect(find.textContaining('成员'), findsWidgets, reason: '信息 tab 成员区未渲染');
    debugPrint('[smoke] panel open + info tab OK');

    // 3. 切「变更」tab:真实 session.diff RPC(server → m2 plugin → git)
    final diffKey = (agentId: conv.agent!.id, convId: conv.id);
    await tester.tap(find.text('变更'));
    await tester.pump(const Duration(milliseconds: 300));
    // autoDispose 保活(T5 陷阱:read 轮询会建短命实例)
    final diffSub = container.listen(sessionDiffProvider(diffKey), (_, _) {});
    addTearDown(diffSub.close);
    final diffState = await _until(
      () => container.read(sessionDiffProvider(diffKey)),
      (s) => s.hasValue && (s.value ?? const []).isNotEmpty,
      timeout: const Duration(seconds: 20),
      reason: 'session.diff 未返回数据(agent 离线或 RPC 失败)',
    );
    final files = diffState.value!;
    await tester.pump(const Duration(milliseconds: 500));

    final byName = {
      for (final f in files) (f.file ?? ''): f,
    };
    debugPrint('[smoke] session.diff: ${files.length} files: '
        '${files.map((f) => '${f.file}(binary=${f.binary},truncated=${f.truncated},+${f.additions}/−${f.deletions})').join(', ')}');
    expect(files.length, greaterThanOrEqualTo(3), reason: '期望 ≥3 个变更文件');
    expect(byName.containsKey('tracked.txt'), isTrue, reason: '缺 tracked 修改文件');
    expect(byName.containsKey('logo.png'), isTrue, reason: '缺二进制文件');
    expect(byName['logo.png']!.binary, isTrue, reason: 'logo.png 未标 binary');
    expect(byName.containsKey('big.log'), isTrue, reason: '缺截断文件');
    expect(byName['big.log']!.truncated, isTrue, reason: 'big.log 未标 truncated');

    // 4. 列表渲染:文件名 + 状态标记(作用域限 DetailPanel,防 LLM 流式
    //    回复气泡文案干扰 finder)
    final panelScope = find.byType(DetailPanel);
    expect(
        find.descendant(
            of: panelScope, matching: find.textContaining('tracked.txt')),
        findsOneWidget);
    expect(
        find.descendant(
            of: panelScope, matching: find.textContaining('logo.png')),
        findsOneWidget);
    expect(
        find.descendant(
            of: panelScope, matching: find.textContaining('big.log')),
        findsOneWidget);
    expect(
        find.descendant(of: panelScope, matching: find.text('二进制')),
        findsOneWidget,
        reason: 'binary 标记未渲染');
    expect(
        find.descendant(of: panelScope, matching: find.text('已截断')),
        findsOneWidget,
        reason: 'truncated 标记未渲染');
    debugPrint('[smoke] file list + markers OK');

    // 5. 展开正常文件:patch 行(hunk 头 + +/- 行)。tap 用 ExpansionTile key
    Future<void> expandFile(String name) async {
      await tester.ensureVisible(find.byKey(ValueKey('diff_file_$name')));
      await tester.tap(find.byKey(ValueKey('diff_file_$name')),
          warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));
    }

    await expandFile('tracked.txt');
    expect(
        find.descendant(of: panelScope, matching: find.textContaining('@@')),
        findsWidgets,
        reason: 'hunk 头未渲染');
    expect(
        find.descendant(
            of: panelScope, matching: find.textContaining('+MODIFIED-by-t7')),
        findsOneWidget,
        reason: '新增行未渲染');
    expect(
        find.descendant(
            of: panelScope, matching: find.textContaining('-line2')),
        findsOneWidget,
        reason: '删除行未渲染');
    debugPrint('[smoke] patch view OK');

    // 6. 展开二进制文件:「二进制文件」占位
    await expandFile('logo.png');
    expect(
        find.descendant(of: panelScope, matching: find.text('二进制文件')),
        findsOneWidget,
        reason: '二进制占位未渲染');
    debugPrint('[smoke] binary placeholder OK');

    // 7. 展开截断文件:「已截断,共 N 行」提示(N=接收行数,含 plugin 追加的
    //    省略行;plugin 侧自己的半角省略行也在 patch 里渲染)
    await expandFile('big.log');
    final clamped = byName['big.log']!;
    final n = clamped.patch!.trimRight().split('\n').length;
    expect(
        find.descendant(
            of: panelScope, matching: find.text('已截断，共 $n 行')),
        findsOneWidget,
        reason: '截断提示行数不符');
    expect(
        find.descendant(
            of: panelScope, matching: find.textContaining('已截断,共 ')),
        findsWidgets,
        reason: 'plugin 侧省略行未随 patch 渲染');
    debugPrint('[smoke] truncated hint OK (n=$n)');

    // 8. 收起面板
    await tester.tap(find.byTooltip('关闭详情'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DetailPanel), findsNothing, reason: '面板未收起');

    debugPrint('[smoke] ALL PASS');
  });
}

Future<T> _until<T>(
  T Function() read,
  bool Function(T) condition, {
  Duration timeout = const Duration(seconds: 10),
  String reason = 'timeout',
}) async {
  final deadline = DateTime.now().add(timeout);
  T v = read();
  while (!condition(v)) {
    if (DateTime.now().isAfter(deadline)) {
      throw 'timeout: $reason, last=$v';
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    v = read();
  }
  return v;
}
