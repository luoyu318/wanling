// profile 授权弹窗接线测试 —— wanlingGetProfile 调用式授权的 UI 流转。
// 照 mini_program_permission_flow 既有用例模式:弹窗可独立泵起,
// 验证固定文案与允许/拒绝/点遮罩三态流转(拒绝语义对齐 M2 权限弹窗)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/pages/mini_program_page.dart';

void main() {
  /// 泵起宿主页并打开弹窗(断言文案须在 [act] 前做,点按钮即关弹窗)。
  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showProfileConsentDialog(ctx),
              child: const Text('trigger'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
  }

  Future<bool> settleAllow(WidgetTester tester, String action) async {
    var allowed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async => allowed = await showProfileConsentDialog(ctx),
              child: const Text('trigger'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('trigger'));
    await tester.pumpAndSettle();
    if (action == '允许' || action == '拒绝') {
      await tester.tap(find.text(action));
    } else {
      // 点遮罩(barrierDismissible 默认 true)
      await tester.tapAt(const Offset(10, 10));
    }
    await tester.pumpAndSettle();
    return allowed;
  }

  testWidgets('弹窗展示固定文案(标题+正文+允许/拒绝按钮)', (tester) async {
    await openDialog(tester);
    expect(find.text('身份信息授权'), findsOneWidget);
    expect(find.text('将向该小程序提供你的昵称、头像与用户标识'), findsOneWidget);
    expect(find.text('允许'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
  });

  testWidgets('点允许 → true', (tester) async {
    expect(await settleAllow(tester, '允许'), isTrue);
  });

  testWidgets('点拒绝 → false', (tester) async {
    expect(await settleAllow(tester, '拒绝'), isFalse);
  });

  testWidgets('点遮罩 → 视为拒绝 false', (tester) async {
    expect(await settleAllow(tester, 'barrier'), isFalse);
  });
}
