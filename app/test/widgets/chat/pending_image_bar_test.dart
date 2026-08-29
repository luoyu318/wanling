import 'package:app/widgets/chat/pending_image_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// 经 wechat_assets_picker 重导出的 photo_manager 类型(AssetEntity/AssetType),
// 避免测试直接依赖 transitive 包(depend_on_referenced_packages)
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

// photo_manager 与宿主的通信通道(缩略图读取走这里)
const String _pmChannel = 'com.fluttercandies/photo_manager';

// 合法 1x1 PNG 字节,让 AssetEntityImageProvider 真正解码成功。
// 不能让加载走失败路径:photo_manager_image_provider 的 _loadAsync 在
// kDebugMode 下会主动 FlutterError.presentError,widget 测试中会被计为失败。
const List<int> _kPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0xFF, 0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

/// 仅 override provider 加载链必需的字段,其余走 noSuchMethod 兜底:
/// - type=image:绕开 audio/other 的 UnsupportedError 分支与缩略图断言
/// - mimeType=jpeg:_getType 读后缀判定图片类型,避免再走 titleAsync 通道
/// - id:getThumbnail 参数需要
class _FakeAsset implements AssetEntity {
  @override
  AssetType get type => AssetType.image;
  @override
  String get id => 'fake-id';
  @override
  String? get mimeType => 'jpeg';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('渲染缩略图容器与删除按钮,点删除回调', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(_pmChannel),
      (call) async => call.method == 'getThumb'
          ? Uint8List.fromList(_kPng)
          : null,
    );

    var removed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PendingImageBar(
          asset: _FakeAsset(),
          onRemove: () => removed = true,
        ),
      ),
    ));
    // pump 不带 duration 只 flush 微任务;这里需 elapse 消费
    // _loadAsync 里 Future(() ...) 创建的 duration-0 timer,否则
    // 测试结束因 pending timer 断言失败。
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(find.byIcon(Icons.close), findsOneWidget);
    expect(find.byType(Image), findsOneWidget); // AssetEntityImageProvider 加载中/失败也渲染 Image

    await tester.tap(find.byIcon(Icons.close));
    expect(removed, isTrue);
  });
}
