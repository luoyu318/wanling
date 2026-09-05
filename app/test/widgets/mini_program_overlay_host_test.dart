// 小程序嵌入模式弹层宿主测试(C1):
// 机制:MiniProgramHost 挂 MaterialApp.builder,Navigator 是 Host Stack 的
// child;嵌入页面与 Navigator 是兄弟分支,其 context 向上无 NavigatorState,
// showDialog/showModalBottomSheet 的 Navigator.of 直接抛 FlutterError。
// 修复方案:Host Stack 顶端(实例视图之上)挂专用全局 Overlay 作弹层宿主,
// 嵌入模式 4 处弹层(更多抽屉/profile 授权/权限申请/会话选择器)改经它呈现。
// 注:弹层宿主属于 Host 保活层的一部分,与 mini_program_host_test 的差异
// 在本文件统一使用真实 embedded 页(禁用态 info 避开 WebView 平台通道)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:app/pages/mini_program_launch_page.dart';
import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/router.dart' show routerProvider;
import 'package:app/services/mini_program_launcher.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/widgets/feedback/app_dialog.dart';
import 'package:app/widgets/mini_program_conversation_picker.dart';
import 'package:app/widgets/mini_program_host.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/conversation_provider.dart'
    show ConversationListNotifier, conversationProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';

import '../helpers/fake_ws.dart';

class _MockApi extends Mock implements ApiService {}

Conversation _conv(String id, String title) => Conversation(
      id: id,
      type: 'group',
      title: title,
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime(2026),
      createdAt: DateTime(2026),
    );

const _infoA = MiniProgramInfo(
  id: 'mp1',
  appid: 'a',
  ownerId: 'u1',
  name: 'MP A',
  version: 1,
  // 禁用态:build 提前返回静态文案,不创建 InAppWebView(测试无平台通道)
  status: 'disabled',
  sha256: 'deadbeef',
  size: 1,
);

/// 测试脚手架:真实 manager + 最小真实路由(含 live 壳) + Host 接线,
/// 真实 embedded 页渲染「已停用」静态文案(与 mini_program_host_test 同构)。
class _Harness {
  final MiniProgramManager manager = MiniProgramManager();
  late final GoRouter router;
  late final ProviderContainer container;

  /// instanceViewBuilder 回调捕获的嵌入侧 context(helper 接线测试用)
  BuildContext? triggerContext;

  Future<void> pump(
    WidgetTester tester, {
    List<MiniProgramInfo> mpInfos = const [],
    Widget Function(BuildContext, MiniProgramInstance)? instanceViewBuilder,
    List<Override> overrides = const [],
  }) async {
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Text('home-body')),
        ),
        GoRoute(
          path: '/mini-program-live/:appid',
          pageBuilder: (context, state) => NoTransitionPage<void>(
            key: state.pageKey,
            child: const MiniProgramLiveShellPage(),
          ),
        ),
      ],
    );
    container = ProviderContainer(overrides: [
      miniProgramManagerProvider.overrideWith((ref) => manager),
      routerProvider.overrideWithValue(router),
      miniProgramsProvider.overrideWith((ref) async => mpInfos),
      ...overrides,
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MiniProgramHost(
          instanceViewBuilder: instanceViewBuilder,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(() {
    resetLauncherForTest();
  });

  testWidgets('C1 回归网:embedded 页胶囊「⋯」弹「更多」抽屉不崩(经宿主 Overlay)',
      (tester) async {
    final h = _Harness();
    await h.pump(tester, mpInfos: [_infoA]);

    openMiniProgramWith(h.container, 'a');
    await tester.pumpAndSettle();

    // 胶囊两个 InkWell:第一个 = ⋯(更多),第二个 = ◉(关闭)
    final capsuleInkWells = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(InkWell),
    );
    expect(capsuleInkWells, findsNWidgets(2));
    await tester.tap(capsuleInkWells.first);
    await tester.pumpAndSettle();

    // 修复前:showModalBottomSheet 的 Navigator.of 在 embedded context 上
    // 抛 FlutterError,抽屉永远出不来;修复后抽屉内容完整渲染
    expect(find.text('MP A'), findsWidgets);
    expect(find.text('浮窗'), findsOneWidget);
    expect(find.text('刷新'), findsOneWidget);
    expect(find.text('分享到会话'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);

    // 点「关闭」收起抽屉
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('浮窗'), findsNothing);
  });

  /// 泵一个「实例前台 + 替身实例视图内触发按钮」场景,[onPressed] 在嵌入
  /// 页面 context 中执行(helper 层接线测试的统一入口)。
  Future<void> pumpTrigger(
    WidgetTester tester,
    _Harness h,
    VoidCallback onPressed,
  ) async {
    await h.pump(
      tester,
      instanceViewBuilder: (context, inst) {
        h.triggerContext = context;
        return Center(
          child: ElevatedButton(
            onPressed: () => onPressed(),
            child: const Text('trigger'),
          ),
        );
      },
    );
    h.manager.open('a');
    await tester.pumpAndSettle();
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
  }

  testWidgets('showAppDialog(embedded) 经宿主 Overlay 呈现,允许回调且自动关闭',
      (tester) async {
    final h = _Harness();
    var allowed = false;
    await pumpTrigger(tester, h, () {
      unawaited(showAppDialog(
        context: h.triggerContext!,
        embedded: true,
        title: '身份信息授权',
        content: const Text('授权内容'),
        confirmText: '允许',
        cancelText: '拒绝',
        onConfirm: () => allowed = true,
      ));
    });

    // 弹层渲染(宿主 Overlay 之上,barrier 覆盖)
    expect(find.text('身份信息授权'), findsOneWidget);
    expect(find.text('授权内容'), findsOneWidget);
    expect(find.text('trigger'), findsOneWidget); // 实例视图仍在弹层之下

    await tester.tap(find.text('允许'));
    await tester.pumpAndSettle();
    expect(allowed, isTrue);
    expect(find.text('身份信息授权'), findsNothing); // 自动关闭
  });

  testWidgets('showAppDialog(embedded) 点遮罩=拒绝并关闭(barrier 语义保持)',
      (tester) async {
    final h = _Harness();
    var allowed = false;
    await pumpTrigger(tester, h, () {
      unawaited(showAppDialog(
        context: h.triggerContext!,
        embedded: true,
        title: '权限申请',
        content: const Text('申请内容'),
        confirmText: '允许',
        cancelText: '拒绝',
        onConfirm: () => allowed = true,
      ));
    });
    expect(find.text('权限申请'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('权限申请'), findsNothing);
    expect(allowed, isFalse);
  });

  testWidgets('前台实例变化(最小化)→ 嵌入弹层自动关闭(不悬浮到宿主页面)',
      (tester) async {
    final h = _Harness();
    await pumpTrigger(tester, h, () {
      unawaited(showAppDialog(
        context: h.triggerContext!,
        embedded: true,
        title: '身份信息授权',
        content: const Text('授权内容'),
      ));
    });
    expect(find.text('身份信息授权'), findsOneWidget);

    h.manager.minimize();
    await tester.pumpAndSettle();
    expect(find.text('身份信息授权'), findsNothing);
  });

  testWidgets('会话选择器 embedded 变体:经宿主 Overlay 呈现,点会话回传 convId',
      (tester) async {
    final api = _MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
    final h = _Harness();
    final picked = Completer<String?>();
    await h.pump(
      tester,
      instanceViewBuilder: (context, inst) => Consumer(
        builder: (ctx, ref, _) => Center(
          child: ElevatedButton(
            onPressed: () async => picked.complete(
                await showMiniProgramConversationPicker(
                    context: ctx, ref: ref, embedded: true)),
            child: const Text('trigger'),
          ),
        ),
      ),
      // 会话数据:autoload 关闭 + 直接赋 state(对齐既有 picker 测试,
      // 避免真实网络调用)
      overrides: [
        conversationProvider.overrideWith((ref) => ConversationListNotifier(
            api, FakeWS(), 'u1', NoopLocalMessageStore(),
            autoload: false)),
      ],
    );
    h.container.read(conversationProvider.notifier).state = [
      _conv('c1', '测试群'),
    ];
    h.manager.open('a');
    await tester.pumpAndSettle();
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();

    expect(find.text('分享到'), findsOneWidget);
    expect(find.text('测试群'), findsOneWidget);

    await tester.tap(find.text('测试群'));
    await tester.pumpAndSettle();
    expect(await picked.future, 'c1');
    expect(find.text('分享到'), findsNothing);
  });
}
