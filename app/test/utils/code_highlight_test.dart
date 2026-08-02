import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:highlight/highlight.dart' show Node;

import 'package:app/utils/code_highlight.dart';

void main() {
  group('languageFromPath', () {
    test('已知扩展名 → 对应语言', () {
      expect(languageFromPath('main.go'), 'go');
      expect(languageFromPath('app.dart'), 'dart');
      expect(languageFromPath('index.ts'), 'typescript');
      expect(languageFromPath('index.tsx'), 'typescript');
      expect(languageFromPath('README.md'), 'markdown');
      expect(languageFromPath('config.yaml'), 'yaml');
      expect(languageFromPath('config.yml'), 'yaml');
      expect(languageFromPath('data.json'), 'json');
    });

    test('大小写不敏感', () {
      expect(languageFromPath('Main.GO'), 'go');
      expect(languageFromPath('APP.DART'), 'dart');
    });

    test('未知扩展名 → plaintext', () {
      expect(languageFromPath('unknown.xyz'), 'plaintext');
      expect(languageFromPath('noext'), 'plaintext');
    });

    test('空路径 → plaintext', () {
      expect(languageFromPath(''), 'plaintext');
    });
  });

  group('highlightNodesToSpans', () {
    test('空列表 → 空列表', () {
      expect(highlightNodesToSpans(const [], const {}), isEmpty);
    });

    test('单层 value Node → 单个 TextSpan', () {
      const theme = <String, TextStyle>{'root': TextStyle(color: Color(0xFF000000))};
      final nodes = [Node(value: 'hello')];
      final spans = highlightNodesToSpans(nodes, theme);
      expect(spans.length, 1);
      expect(spans.first.text, 'hello');
    });

    test('带 className 的 Node → 应用 theme 样式', () {
      const theme = <String, TextStyle>{
        'keyword': TextStyle(color: Color(0xFF0000FF)),
      };
      final nodes = [Node(className: 'keyword', value: 'import')];
      final spans = highlightNodesToSpans(nodes, theme);
      expect(spans.length, 1);
      expect(spans.first.style?.color, const Color(0xFF0000FF));
    });
  });
}
