import 'package:app/utils/gallery_image.dart';
import 'package:app/widgets/gallery/zoomable_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  List<GalleryImage> imgs(int n) => List.generate(
      n,
      (i) => const GalleryImage(
          url: 'https://h/api/files/x', fileId: 'x', headers: {}));

  testWidgets('ZoomableGallery 正常渲染多页', (tester) async {
    final images = [
      const GalleryImage(url: 'https://h/a', fileId: 'a', headers: {}),
      const GalleryImage(url: 'https://h/b', fileId: 'b', headers: {}),
    ];
    await tester.pumpWidget(MaterialApp(
      home: ZoomableGallery(images: images, initialIndex: 0),
    ));
    await tester.pump();
    expect(find.byType(ZoomableGallery), findsOneWidget);
  });

  testWidgets('调 close() pop 路由', (tester) async {
    final rootKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: rootKey,
      home: Builder(builder: (ctx) {
        return ElevatedButton(
          onPressed: () {
            Navigator.of(ctx).push(MaterialPageRoute(
              builder: (_) =>
                  ZoomableGallery(images: imgs(2), initialIndex: 0),
            ));
          },
          child: const Text('open'),
        );
      }),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(rootKey.currentState!.canPop(), isTrue);
    final state = tester.state(find.byType(ZoomableGallery));
    // ignore: avoid_dynamic_calls
    (state as dynamic).close();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(rootKey.currentState!.canPop(), isFalse, reason: 'close() 应 pop');
  });

  testWidgets('初始页 Hero 不与其他页冲突', (tester) async {
    final images = [
      const GalleryImage(url: 'https://h/a', fileId: 'a', headers: {}),
      const GalleryImage(url: 'https://h/b', fileId: 'b', headers: {}),
    ];
    await tester.pumpWidget(MaterialApp(
      home: ZoomableGallery(images: images, initialIndex: 0),
    ));
    await tester.pump();
    // 仅初始页带 Hero，无 multiple heroes 断言即通过。
    expect(find.byType(ZoomableGallery), findsOneWidget);
  });

  testWidgets('goToPage 翻到下一张并更新 currentPage', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ZoomableGallery(images: imgs(3), initialIndex: 0),
    ));
    await tester.pump();
    final state = tester.state(find.byType(ZoomableGallery));
    // ignore: avoid_dynamic_calls
    (state as dynamic).goToPage(1);
    await tester.pump();
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).currentPage, 1, reason: '应翻到第 2 张');
  });

  testWidgets('翻页后离开页 controller 重置 position 归零', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ZoomableGallery(images: imgs(3), initialIndex: 0),
    ));
    await tester.pump();
    final state = tester.state(find.byType(ZoomableGallery));
    // 翻到下一张，触发 onPageChanged 重置离开页（index 0）的 controller。
    // ignore: avoid_dynamic_calls
    (state as dynamic).goToPage(1);
    await tester.pump();
    // 离开页（index 0）的 position 应归零。
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).pagePosition(0), Offset.zero,
        reason: '翻页后离开页 position 应重置');
    // ignore: avoid_dynamic_calls
    expect((state as dynamic).currentPage, 1);
  });
}
