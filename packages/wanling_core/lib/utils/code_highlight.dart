import 'package:flutter/material.dart';
import 'package:highlight/highlight.dart' show Node;

/// 文件路径 → highlight 库语言名。未知扩展名返 'plaintext'(避免 autoDetection 性能开销)。
String languageFromPath(String path) {
  if (path.isEmpty) return 'plaintext';
  final dot = path.lastIndexOf('.');
  if (dot < 0) return 'plaintext';
  final ext = path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'dart' => 'dart',
    'go' => 'go',
    'ts' => 'typescript',
    'tsx' => 'typescript',
    'js' => 'javascript',
    'jsx' => 'javascript',
    'py' => 'python',
    'rs' => 'rust',
    'md' => 'markdown',
    'yaml' || 'yml' => 'yaml',
    'json' => 'json',
    'sh' || 'bash' => 'bash',
    'sql' => 'sql',
    'java' => 'java',
    'kt' || 'kts' => 'kotlin',
    'xml' => 'xml',
    'html' => 'xml',
    'css' => 'css',
    'toml' => 'ini',
    _ => 'plaintext',
  };
}

/// highlight 库 Node 树 → Flutter TextSpan 列表。共用转换逻辑,
/// 保留跨行注释/字符串的高亮上下文。
List<TextSpan> highlightNodesToSpans(List<Node> nodes, Map<String, TextStyle> theme) {
  final spans = <TextSpan>[];
  var currentSpans = spans;
  final stack = <List<TextSpan>>[];

  void traverse(Node node) {
    if (node.value != null) {
      currentSpans.add(node.className == null
          ? TextSpan(text: node.value)
          : TextSpan(text: node.value, style: theme[node.className!]));
    } else if (node.children != null) {
      final tmp = <TextSpan>[];
      currentSpans.add(TextSpan(children: tmp, style: theme[node.className!]));
      stack.add(currentSpans);
      currentSpans = tmp;
      final children = node.children!;
      for (final n in children) {
        traverse(n);
        if (n == children.last) {
          currentSpans = stack.isEmpty ? spans : stack.removeLast();
        }
      }
    }
  }

  for (final node in nodes) {
    traverse(node);
  }
  return spans;
}
