import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/services/mini_program_service.dart';

Uint8List buildZip(Map<String, List<int>> files) {
  final archive = Archive();
  files.forEach((name, content) {
    final bytes = Uint8List.fromList(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('isSafeEntryName', () {
    test('拒绝绝对路径/穿越/反斜杠', () {
      expect(MiniProgramService.isSafeEntryName('/etc/passwd'), isFalse);
      expect(MiniProgramService.isSafeEntryName('../evil.js'), isFalse);
      expect(MiniProgramService.isSafeEntryName('a\\b.js'), isFalse);
      expect(MiniProgramService.isSafeEntryName('js/app.js'), isTrue);
      expect(MiniProgramService.isSafeEntryName('index.html'), isTrue);
    });
  });

  group('verifySha256', () {
    test('匹配通过,不匹配抛异常', () {
      final bytes = Uint8List.fromList('hello'.codeUnits);
      // sha256('hello') = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
      MiniProgramService.verifySha256(bytes,
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824');
      expect(
        () => MiniProgramService.verifySha256(bytes, 'deadbeef'),
        throwsA(anything),
      );
    });
  });

  group('extractPackage', () {
    test('解压到目标目录,目录结构保留', () async {
      final dir = await Directory.systemTemp.createTemp('mp_extract_test');
      addTearDown(() => dir.delete(recursive: true));
      final zip = buildZip({
        'index.html': '<html></html>'.codeUnits,
        'js/app.js': 'console.log(1)'.codeUnits,
      });
      await MiniProgramService.extractPackage(zip, dir);
      expect(File('${dir.path}/index.html').existsSync(), isTrue);
      expect(File('${dir.path}/js/app.js').existsSync(), isTrue);
    });

    test('包内路径穿越条目直接抛异常,不落盘', () async {
      final dir = await Directory.systemTemp.createTemp('mp_extract_test');
      addTearDown(() => dir.delete(recursive: true));
      final zip = buildZip({
        'index.html': 'x'.codeUnits,
        '../evil.js': 'x'.codeUnits,
      });
      expect(
        () => MiniProgramService.extractPackage(zip, dir),
        throwsA(anything),
      );
    });
  });
}