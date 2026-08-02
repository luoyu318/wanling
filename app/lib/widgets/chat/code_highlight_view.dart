import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/a11y-light.dart';
import 'package:highlight/highlight.dart' show highlight;

import '../../utils/code_highlight.dart';
import '../feedback/app_text_selection_toolbar.dart';

class CodeHighlightView extends StatefulWidget {
  final String code;
  final String path;
  final bool truncated;
  final int fileSizeBytes;

  const CodeHighlightView({
    super.key,
    required this.code,
    required this.path,
    required this.truncated,
    required this.fileSizeBytes,
  });

  @override
  State<CodeHighlightView> createState() => _CodeHighlightViewState();
}

class _CodeHighlightViewState extends State<CodeHighlightView> {
  final FocusNode _selectionFocusNode = FocusNode();

  @override
  void dispose() {
    _selectionFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const theme = a11yLightTheme;
    const fontStyle = TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.5);

    final language = languageFromPath(widget.path);
    final result = highlight.parse(widget.code, language: language);
    final spans = highlightNodesToSpans(result.nodes ?? const [], theme);

    final lines = widget.code.isEmpty ? <String>[] : widget.code.split('\n');
    final lineCount = lines.length;

    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                  color: const Color(0xFFFAFAFA),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (var i = 1; i <= lineCount; i++)
                        Text(
                          '$i',
                          style: fontStyle.copyWith(
                              color: const Color(0xFFBBBBBB)),
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ColoredBox(
                    color: theme['root']?.backgroundColor ?? Colors.white,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            vertical: 12, horizontal: 12),
                        child: SelectableRegion(
                          focusNode: _selectionFocusNode,
                          selectionControls:
                              materialTextSelectionHandleControls,
                          contextMenuBuilder: (context, selectableRegionState) {
                            return AppTextSelectionToolbar(
                              buttonItems:
                                  selectableRegionState.contextMenuButtonItems,
                              anchors:
                                  selectableRegionState.contextMenuAnchors,
                            );
                          },
                          child: Text.rich(
                            TextSpan(
                              style: fontStyle.copyWith(
                                  color: theme['root']?.color ??
                                      const Color(0xFF222222)),
                              children: spans,
                            ),
                            softWrap: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (widget.truncated)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: const BoxDecoration(
              color: Color(0xFFFFF8E1),
              border: Border(
                left: BorderSide(color: Color(0xFFFA9D3B), width: 2),
              ),
            ),
            child: Text(
              '⚠ 文件超过 ${_formatBytes(widget.fileSizeBytes)},只显示前部分',
              style: const TextStyle(fontSize: 11, color: Color(0xFF666666)),
            ),
          ),
      ],
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
