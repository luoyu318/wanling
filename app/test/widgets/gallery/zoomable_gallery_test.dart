import 'package:app/utils/gallery_image.dart';
import 'package:app/widgets/gallery/zoomable_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('长按图片弹出底部菜单含「保存图片」', (tester) async {
    // mock Gal.putImage（保存时调用，避免原生调用报错）
    const galChannel = MethodChannel('gal');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(galChannel, (call) async => null);

    final images = [
      const GalleryImage(
          url: 'https://ex.com/api/files/1', fileId: '1', headers: {}),
    ];
    await tester.pumpWidget(MaterialApp(
      home: ZoomableGallery(images: images, initialIndex: 0),
    ));
    await tester.pump();

    // 长按画廊（tester.longPress 内部 pump 足够时长触发 500ms 计时）。
    // 用 pump（固定时长）而非 pumpAndSettle：CachedNetworkImage 加载网络图不 settle。
    await tester.longPress(find.byType(ZoomableGallery));
    await tester.pump(const Duration(milliseconds: 100));

    // BottomSheet 弹出，含「保存图片」
    expect(find.text('保存图片'), findsOneWidget);

    // 清理 mock
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(galChannel, null);
  });

  testWidgets('长按后移动取消（拖动不弹菜单）', (tester) async {
    final images = [
      const GalleryImage(
          url: 'https://ex.com/api/files/1', fileId: '1', headers: {}),
    ];
    await tester.pumpWidget(MaterialApp(
      home: ZoomableGallery(images: images, initialIndex: 0),
    ));
    await tester.pump();

    // 用 TestGesture 精确控制 down/move 时序
    final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ZoomableGallery)));
    await tester.pump(const Duration(milliseconds: 200));
    // 移动 40px（> 18 阈值）→ 取消长按
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 100));

    // 不应弹菜单
    expect(find.text('保存图片'), findsNothing);
  });
}
