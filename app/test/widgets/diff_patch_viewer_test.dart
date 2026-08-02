import 'package:app/widgets/chat/diff_patch_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const samplePatch = '''@@ -45,7 +45,12 @@ func init()
 func init() {
   cfg := loadConfig()
-  oldLine()
+  newFunc()
+  if err != nil {
+    log.Fatal(err)
+  }
   serve(cfg)
 }''';

  testWidgets('渲染 hunk header / context / add / del 行', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DiffPatchViewer(patch: samplePatch),
        ),
      ),
    );

    expect(find.textContaining('@@ -45,7 +45,12 @@'), findsOneWidget);
    expect(find.textContaining('func init()'), findsNWidgets(2));
    expect(find.textContaining('-  oldLine()'), findsOneWidget);
    expect(find.textContaining('+  newFunc()'), findsOneWidget);
    expect(find.textContaining('+  if err != nil'), findsOneWidget);
  });

  testWidgets('空 patch 字符串不崩,显"无变更内容"', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DiffPatchViewer(patch: ''),
        ),
      ),
    );

    expect(find.text('无变更内容'), findsOneWidget);
  });

  testWidgets('add/del 行用 monospace 字体', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DiffPatchViewer(patch: '- old\n+ new'),
        ),
      ),
    );

    final textWidgets = tester.widgetList<Text>(find.byType(Text));
    final codeLines = textWidgets.where((t) {
      final s = t.data ?? '';
      return s.startsWith('-') || s.startsWith('+');
    });
    expect(codeLines, isNotEmpty);
    for (final t in codeLines) {
      expect(t.style?.fontFamily, 'monospace');
    }
  });
}
