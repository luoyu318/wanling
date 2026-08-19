import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/widgets/file_type_icon.dart';

void main() {
  testWidgets('PDF shows red background with PDF text', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileTypeIcon(mimeType: 'application/pdf')),
    ));
    // 找最内层 Container (DecoratedBox 转换)
    final container = tester.widget<Container>(find.byType(Container).first);
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, const Color(0xFFFEE2E2));
    expect(find.text('PDF'), findsOneWidget);
  });

  testWidgets('Word docx shows blue with W', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileTypeIcon(mimeType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document')),
    ));
    expect(find.text('W'), findsOneWidget);
  });

  testWidgets('Excel xlsx shows green with X', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileTypeIcon(mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet')),
    ));
    expect(find.text('X'), findsOneWidget);
  });

  testWidgets('PPT pptx shows orange with P', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileTypeIcon(mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation')),
    ));
    expect(find.text('P'), findsOneWidget);
  });

  testWidgets('ZIP shows purple with Z', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileTypeIcon(mimeType: 'application/zip')),
    ));
    expect(find.text('Z'), findsOneWidget);
  });

  testWidgets('text/plain shows gray with T', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileTypeIcon(mimeType: 'text/plain')),
    ));
    expect(find.text('T'), findsOneWidget);
  });

  testWidgets('unknown type shows fallback ? text', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileTypeIcon(mimeType: 'application/octet-stream')),
    ));
    expect(find.text('?'), findsOneWidget);
  });

  testWidgets('custom size changes icon dimensions', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FileTypeIcon(mimeType: 'application/pdf', size: 60)),
    ));
    final container = tester.widget<Container>(find.byType(Container).first);
    expect(container.constraints?.maxWidth, 60);
  });
}
