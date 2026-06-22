import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/copyable_field.dart';

// 注：mock clipboard 必须用 SystemChannels.platform（OptionalMethodChannel 单例），
// 不能 new MethodChannel('flutter/platform') ——后者是不同实例，setMockMethodCallHandler 不生效。

void main() {
  group('CopyableField', () {
    testWidgets('secret=true 默认掩码显示', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CopyableField(label: '密钥', value: 'sk123456', secret: true)),
      ));
      expect(find.text('••••••••'), findsOneWidget);
      expect(find.text('sk123456'), findsNothing);
    });

    testWidgets('secret=false 直接显示原值', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CopyableField(label: 'AppID', value: 'abc123')),
      ));
      expect(find.text('abc123'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_outlined), findsNothing);
    });

    testWidgets('点眼睛图标切换显示', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CopyableField(label: '密钥', value: 'sk123456', secret: true)),
      ));
      // 默认掩码
      expect(find.text('••••••••'), findsOneWidget);
      // 点击眼睛
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pump();
      // 现在显示明文
      expect(find.text('sk123456'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    });

    testWidgets('点复制图标写入剪贴板', (tester) async {
      // 设置 mock 剪贴板 channel
      // Clipboard.setData 走 SystemChannels.platform，method 为 'Clipboard.setData'。
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'];
        }
        return null;
      });

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: CopyableField(label: 'AppID', value: 'abc123')),
      ));
      await tester.tap(find.byIcon(Icons.copy_outlined));
      await tester.pumpAndSettle();

      expect(copied, 'abc123');
      expect(find.text('已复制'), findsOneWidget);
    });
  });
}
