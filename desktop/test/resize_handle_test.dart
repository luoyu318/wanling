// desktop/test/resize_handle_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_desktop/providers/conv_list_width_provider.dart';
import 'package:wanling_desktop/shell/resize_handle.dart';

void main() {
  testWidgets('向右拖拽 60px 增宽会话列表 60', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ResizeHandle())),
      ),
    );
    final before = container.read(convListWidthProvider);
    final center = tester.getCenter(find.byType(ResizeHandle));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(60, 0));
    await gesture.up();
    await tester.pump();
    expect(container.read(convListWidthProvider), before + 60);
  });

  testWidgets('拖出上界 clamp 400', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ResizeHandle())),
      ),
    );
    final center = tester.getCenter(find.byType(ResizeHandle));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(500, 0));
    await gesture.up();
    await tester.pump();
    expect(container.read(convListWidthProvider), 400);
  });
}
