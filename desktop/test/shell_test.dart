import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_desktop/pages/messages_page.dart';
import 'package:wanling_desktop/router.dart';
import 'package:wanling_desktop/shell/nav_rail.dart';

void main() {
  testWidgets('路由骨架:/login 渲染登录占位,切 /messages 渲染 shell+导航', (tester) async {
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp.router(routerConfig: router)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsNothing); // 无移动式导航
    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();
    expect(find.byType(MessagesPage), findsOneWidget); // 进入消息页
    expect(find.byType(NavRail), findsOneWidget); // shell 左导航渲染
  });
}
