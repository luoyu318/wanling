import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wanling_core/models/file_entry.dart';
import 'package:app/widgets/chat/file_entry_icon.dart';

void main() {
  testWidgets('目录 → folder 图标 + 蓝色', (tester) async {
    const entry = FileEntry(name: 'src', type: 'dir', size: 0);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.folder);
    expect(icon.color, const Color(0xFF5B7CFA));
    expect(icon.size, 14);
  });

  testWidgets('代码文件 .dart → code 图标 + VSCode Dart 蓝', (tester) async {
    const entry = FileEntry(name: 'main.dart', type: 'file', size: 100);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.code);
    expect(icon.color, const Color(0xFF0175C5));
  });

  testWidgets('代码文件 .go → code 图标 + VSCode Go 青', (tester) async {
    const entry = FileEntry(name: 'main.go', type: 'file', size: 100);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.code);
    expect(icon.color, const Color(0xFF00ADD8));
  });

  testWidgets('代码文件 .ts → code 图标 + VSCode TS 蓝', (tester) async {
    const entry = FileEntry(name: 'index.ts', type: 'file', size: 100);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.code);
    expect(icon.color, const Color(0xFF3178C6));
  });

  testWidgets('代码文件 .js → code 图标 + VSCode JS 黄(深)', (tester) async {
    const entry = FileEntry(name: 'index.js', type: 'file', size: 100);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.code);
    expect(icon.color, const Color(0xFFE6C200));
  });

  testWidgets('代码文件 .py → code 图标 + VSCode Python 蓝', (tester) async {
    const entry = FileEntry(name: 'main.py', type: 'file', size: 100);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.code);
    expect(icon.color, const Color(0xFF3776AB));
  });

  testWidgets('代码文件 .tsx 大小写扩展名 → TS 蓝(走 lowercase)', (tester) async {
    const entry = FileEntry(name: 'App.tsx', type: 'file', size: 100);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.code);
    expect(icon.color, const Color(0xFF3178C6));
  });

  testWidgets('配置文件 Cargo.toml → code 图标 + VSCode TOML 棕', (tester) async {
    const entry = FileEntry(name: 'Cargo.toml', type: 'file', size: 100);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.code);
    expect(icon.color, const Color(0xFF9C4221));
  });

  testWidgets('图片 .png → image 图标 + 紫色', (tester) async {
    const entry = FileEntry(name: 'logo.png', type: 'file', size: 2048);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.image);
    expect(icon.color, const Color(0xFFA855F7));
  });

  testWidgets('压缩包 .zip → folder_zip 图标 + 棕色', (tester) async {
    const entry = FileEntry(name: 'dist.zip', type: 'file', size: 5000);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.folder_zip_outlined);
    expect(icon.color, const Color(0xFFA0744B));
  });

  testWidgets('其他二进制 binary=true → block 图标 + 浅灰', (tester) async {
    const entry = FileEntry(name: 'data.dat', type: 'file', size: 9999, binary: true);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.block);
    expect(icon.color, const Color(0xFFBBBBBB));
  });

  testWidgets('自定义 size → 应用', (tester) async {
    const entry = FileEntry(name: 'main.go', type: 'file', size: 100);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry, size: 20)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.size, 20);
  });

  testWidgets('colorOverride 覆盖默认色(选中态用)', (tester) async {
    const entry = FileEntry(name: 'src', type: 'dir', size: 0);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: FileEntryIcon(entry: entry, colorOverride: Colors.white),
      ),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.color, Colors.white);
  });

  testWidgets('非代码文本文件 .txt → description 图标 + 默认灰', (tester) async {
    const entry = FileEntry(name: 'readme.txt', type: 'file', size: 100);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: FileEntryIcon(entry: entry)),
    ));
    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.icon, Icons.description);
    expect(icon.color, const Color(0xFF888888));
  });
}
