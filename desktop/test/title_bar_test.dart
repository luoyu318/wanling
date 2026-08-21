// desktop/test/title_bar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_desktop/shell/title_bar.dart';

/// 记录调用的 fake WindowActions。
class _FakeActions implements WindowActions {
  int minimizeCalls = 0;
  int maximizeCalls = 0;
  int closeCalls = 0;
  @override
  Future<void> minimize() async => minimizeCalls++;
  @override
  Future<void> toggleMaximize() async => maximizeCalls++;
  @override
  Future<void> close() async => closeCalls++;
  // 抽象含 dragWindow,补 no-op 以满足 implements(测试不断言拖拽)。
  @override
  Future<void> dragWindow() async {}
  @override
  Future<bool> get isMaximized async => false;
  @override
  Stream<void> get onStateChanged => const Stream.empty();
}

void main() {
  // TitleBar 已回退 StatefulWidget(头像移至侧边栏),无需 ProviderScope。
  Future<void> pump(WidgetTester tester, WindowActions actions) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TitleBar(actions: actions),
        ),
      ),
    );
  }

  testWidgets('三个系统按钮分别触发对应动作', (tester) async {
    final actions = _FakeActions();
    await pump(tester, actions);
    await tester.tap(find.byKey(const ValueKey('titlebar_minimize')));
    await tester.tap(find.byKey(const ValueKey('titlebar_maximize')));
    await tester.tap(find.byKey(const ValueKey('titlebar_close')));
    await tester.pump();
    expect(actions.minimizeCalls, 1);
    expect(actions.maximizeCalls, 1);
    expect(actions.closeCalls, 1);
  });

  testWidgets('标题栏无「万灵」文案', (tester) async {
    await pump(tester, _FakeActions());
    expect(find.text('万灵'), findsNothing);
  });
}
