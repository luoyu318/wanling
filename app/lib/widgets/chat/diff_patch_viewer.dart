import 'package:flutter/material.dart';

class DiffLine {
  final String text;
  final DiffLineKind kind;
  final int? newLineNumber;

  const DiffLine({
    required this.text,
    required this.kind,
    this.newLineNumber,
  });
}

enum DiffLineKind { context, addition, deletion, hunkHeader }

List<DiffLine> parsePatch(String patch) {
  if (patch.isEmpty) return const [];
  final lines = patch.split('\n');
  int newLine = 0;
  final result = <DiffLine>[];
  for (final raw in lines) {
    if (raw.isEmpty) continue;
    if (raw.startsWith('@@')) {
      final match = RegExp(r'\+(\d+)(?:,(\d+))?').firstMatch(raw);
      if (match != null) {
        newLine = int.parse(match.group(1)!);
      }
      result.add(DiffLine(text: raw, kind: DiffLineKind.hunkHeader));
      continue;
    }
    if (raw.startsWith('+')) {
      result.add(DiffLine(
        text: raw,
        kind: DiffLineKind.addition,
        newLineNumber: newLine,
      ));
      newLine++;
    } else if (raw.startsWith('-')) {
      result.add(DiffLine(text: raw, kind: DiffLineKind.deletion));
    } else {
      result.add(DiffLine(
        text: raw,
        kind: DiffLineKind.context,
        newLineNumber: newLine,
      ));
      newLine++;
    }
  }
  return result;
}

class DiffPatchViewer extends StatelessWidget {
  final String patch;

  const DiffPatchViewer({super.key, required this.patch});

  @override
  Widget build(BuildContext context) {
    final lines = parsePatch(patch);
    if (lines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: Text(
            '无变更内容',
            style: TextStyle(fontSize: 13, color: Color(0xFF888888)),
          ),
        ),
      );
    }
    return ColoredBox(
      color: const Color(0xFFFAFAFA),
      child: ListView.builder(
        padding: EdgeInsets.zero,
        itemCount: lines.length,
        itemBuilder: (_, i) => _DiffLineRow(line: lines[i]),
      ),
    );
  }
}

class _DiffLineRow extends StatelessWidget {
  final DiffLine line;

  const _DiffLineRow({required this.line});

  @override
  Widget build(BuildContext context) {
    final kind = line.kind;
    if (kind == DiffLineKind.hunkHeader) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          line.text,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 10,
            color: Color(0xFF888888),
            height: 1.4,
          ),
        ),
      );
    }

    final isAdd = kind == DiffLineKind.addition;
    final isDel = kind == DiffLineKind.deletion;
    final bgCode = isAdd
        ? const Color(0xFFE6F7EC)
        : (isDel ? const Color(0xFFFDECEC) : Colors.transparent);
    final lnBgCode = isAdd
        ? const Color(0xFFCDFFD8)
        : (isDel ? const Color(0xFFFFD1D1) : Colors.transparent);
    final fgCode = isAdd
        ? const Color(0xFF074D2C)
        : (isDel ? const Color(0xFF8B1F1F) : const Color(0xFF555555));

    return Container(
      color: bgCode,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            padding: const EdgeInsets.only(right: 6),
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(
              color: lnBgCode,
              border: const Border(
                right: BorderSide(color: Color(0xFFE4E4E4), width: 0.5),
              ),
            ),
            child: Text(
              line.newLineNumber?.toString() ?? '',
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                color: Color(0xFFBBBBBB),
                height: 1.4,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                line.text,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: fgCode,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
