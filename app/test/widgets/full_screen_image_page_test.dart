import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photo_view/photo_view.dart';
import 'package:app/widgets/full_screen_image_page.dart';

void main() {
  testWidgets('渲染 PhotoView + 黑色背景', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FullScreenImagePage(
        url: 'http://example.com/x.png',
        headers: const {'Authorization': 'Bearer token'},
      ),
    ));
    expect(find.byType(PhotoView), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, Colors.black);
  });

  testWidgets('点击关闭页面', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: FullScreenImagePage(
        url: 'http://example.com/x.png',
        headers: const {'Authorization': 'Bearer token'},
      ),
    ));
    await tester.tap(find.byType(GestureDetector));
    await tester.pumpAndSettle();
    expect(find.byType(FullScreenImagePage), findsNothing);
  });
}
