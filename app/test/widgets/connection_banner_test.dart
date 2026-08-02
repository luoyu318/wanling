import 'dart:async';

import 'package:app/providers/auth_provider.dart';
import 'package:app/providers/chat_provider.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/websocket_service.dart';
import 'package:app/widgets/connection_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用 StreamController 模拟 WS 连接状态流,测试 banner 去抖逻辑。
class MockApi extends Mock implements ApiService {}

void main() {
  late StreamController<ConnState> stateController;
  late MockApi api;

  setUp(() {
    // TokenVault 用 FlutterSecureStorage,测试环境需注入内存实现避免挂平台通道。
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    stateController = StreamController<ConnState>.broadcast();
    api = MockApi();
    // mocktail 未 stub 的非空 String getter 返 null 触发 type error。
    when(() => api.baseUrl).thenReturn('http://test.local');
    when(() => api.logout()).thenAnswer((_) async {});
  });

  tearDown(() {
    stateController.close();
  });

  /// pump banner。connStateProvider 用 controller 模拟,authProvider 置
  /// 未登录稳定态(isRestoring/isSwitching/isLoading 全 false)避免 banner 被静默。
  Future<ProviderContainer> pumpBanner(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        connStateProvider.overrideWith((ref) => stateController.stream),
        apiProvider.overrideWithValue(api),
        authProvider.overrideWith((ref) => AuthNotifier(api)),
      ],
    );
    addTearDown(container.dispose);
    // 跑一次 restoreSession 把 AuthNotifier 的 isRestoring 关掉(默认 true 会让
    // banner 视为"过渡期"不显示)。无 token → 立刻 isRestoring=false 返回。
    await container.read(authProvider.notifier).restoreSession();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [ConnectionBanner()],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  group('ConnectionBanner', () {
    testWidgets('connected 时不显示', (tester) async {
      await pumpBanner(tester);
      stateController.add(ConnState.connected);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('当前网络不可用'), findsNothing);
    });

    testWidgets('disconnected 后 3s 显示横幅', (tester) async {
      await pumpBanner(tester);
      stateController.add(ConnState.disconnected);
      await tester.pump();
      // 未到 3s:不显示
      expect(find.textContaining('当前网络不可用'), findsNothing);
      // 到 3s:显示(timer 回调在 pump 推进时触发,需再 pump 一帧渲染)
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.textContaining('当前网络不可用'), findsOneWidget);
    });

    testWidgets('3s 内恢复 connected → 不显示(去抖生效)', (tester) async {
      await pumpBanner(tester);
      stateController.add(ConnState.disconnected);
      await tester.pump(const Duration(seconds: 1));
      stateController.add(ConnState.connected);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(find.textContaining('当前网络不可用'), findsNothing);
    });

    testWidgets('断线已显示 → 收到 connecting 不隐藏(防重连闪烁)', (tester) async {
      // 复现场景:网络断开 → banner 显示 → backoff 到期发起 connect(connecting)
      // 旧实现:connecting 被判为"非断线"立即隐藏,导致 banner 闪烁
      // 期望:已显示后只有 connected 才隐藏
      await pumpBanner(tester);
      stateController.add(ConnState.disconnected);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.textContaining('当前网络不可用'), findsOneWidget,
          reason: '前置:断线 3s 应显示');

      // backoff 到期,WS 发起重连 → connecting
      stateController.add(ConnState.connecting);
      await tester.pump();
      expect(find.textContaining('当前网络不可用'), findsOneWidget,
          reason: '重连中的 connecting 不应隐藏 banner,否则握手指又失败回 '
              'disconnected 时会反复显示/消失闪烁');

      // 握手失败又回 disconnected
      stateController.add(ConnState.disconnected);
      await tester.pump();
      expect(find.textContaining('当前网络不可用'), findsOneWidget);
    });

    testWidgets('断线已显示 → connected 才隐藏', (tester) async {
      await pumpBanner(tester);
      stateController.add(ConnState.disconnected);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.textContaining('当前网络不可用'), findsOneWidget);

      stateController.add(ConnState.connecting);
      await tester.pump();
      expect(find.textContaining('当前网络不可用'), findsOneWidget);

      // 真正连接成功
      stateController.add(ConnState.connected);
      await tester.pump();
      expect(find.textContaining('当前网络不可用'), findsNothing,
          reason: 'connected 应立即隐藏 banner');
    });
  });
}
