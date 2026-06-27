import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:app/utils/image_normalizer.dart';

void main() {
  // dart:ui 需 binding 初始化才能解码
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PNG 转码后输出为 JPEG（findFormatForData == jpg）', () async {
    final src = img.Image(width: 120, height: 80, numChannels: 4);
    img.fill(src, color: img.ColorRgba8(10, 120, 200, 255));
    final pngBytes = Uint8List.fromList(img.encodePng(src));

    final out = await normalizeImageForCrop(pngBytes);
    expect(img.findFormatForData(out), img.ImageFormat.jpg);
  });

  test('小图不放大：转码后尺寸不超过原图最长边', () async {
    final src = img.Image(width: 120, height: 80, numChannels: 4);
    img.fill(src, color: img.ColorRgba8(10, 120, 200, 255));
    final pngBytes = Uint8List.fromList(img.encodePng(src));

    final out = await normalizeImageForCrop(pngBytes);
    final dst = img.decodeJpg(out)!;
    // 仅缩小不放大：目标最长边应 <= 原图最长边（120）
    final dstLongest = dst.width > dst.height ? dst.width : dst.height;
    expect(dstLongest, lessThanOrEqualTo(120));
  });

  test('超大图等比缩放：最长边 = 2048，宽高比保持', () async {
    final big = img.Image(width: 4000, height: 3000, numChannels: 4);
    img.fill(big, color: img.ColorRgba8(200, 50, 50, 255));
    final bigBytes = Uint8List.fromList(img.encodePng(big));

    final out = await normalizeImageForCrop(bigBytes);
    final dst = img.decodeJpg(out)!;
    final dstLongest = dst.width > dst.height ? dst.width : dst.height;
    expect(dstLongest, equals(2048));
    // 等比：宽高比保持 4:3
    expect(dst.width / dst.height, closeTo(4.0 / 3.0, 0.01));
  });

  test('非法字节抛 FormatException（fail fast）', () async {
    final junk = Uint8List.fromList([0, 1, 2, 3, 4]);
    expect(
      () => normalizeImageForCrop(junk),
      throwsA(isA<FormatException>()),
    );
  });
}
