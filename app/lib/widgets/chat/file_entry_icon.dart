import 'package:flutter/material.dart';

import '../../models/file_entry.dart';

const _codeColors = <String, Color>{
  'dart': Color(0xFF0175C5),
  'go': Color(0xFF00ADD8),
  'ts': Color(0xFF3178C6),
  'tsx': Color(0xFF3178C6),
  'js': Color(0xFFE6C200),
  'jsx': Color(0xFFE6C200),
  'mjs': Color(0xFFE6C200),
  'cjs': Color(0xFFE6C200),
  'py': Color(0xFF3776AB),
  'rs': Color(0xFFCE412B),
  'java': Color(0xFFED8B00),
  'kt': Color(0xFF7F52FF),
  'kts': Color(0xFF7F52FF),
  'c': Color(0xFF659AD2),
  'h': Color(0xFF659AD2),
  'cpp': Color(0xFF659AD2),
  'hpp': Color(0xFF659AD2),
  'cc': Color(0xFF659AD2),
  'cxx': Color(0xFF659AD2),
  'cs': Color(0xFF178600),
  'php': Color(0xFF777BB3),
  'rb': Color(0xFFCC342D),
  'swift': Color(0xFFFA7343),
  'md': Color(0xFF555555),
  'markdown': Color(0xFF555555),
  'json': Color(0xFFCBCB41),
  'yaml': Color(0xFFCB171E),
  'yml': Color(0xFFCB171E),
  'toml': Color(0xFF9C4221),
  'sh': Color(0xFF89E051),
  'bash': Color(0xFF89E051),
  'zsh': Color(0xFF89E051),
  'sql': Color(0xFFE38C00),
  'css': Color(0xFF563D7C),
  'scss': Color(0xFF563D7C),
  'less': Color(0xFF563D7C),
  'html': Color(0xFFE44D26),
  'htm': Color(0xFFE44D26),
  'xml': Color(0xFF555555),
};

const _imageExtensions = <String>{
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'bmp', 'ico',
};

const _archiveExtensions = <String>{
  'zip', 'tar', 'gz', 'tgz', 'rar', '7z', 'bz2', 'xz',
};

class FileEntryIcon extends StatelessWidget {
  final FileEntry entry;
  final double size;
  final Color? colorOverride;

  const FileEntryIcon({
    super.key,
    required this.entry,
    this.size = 14,
    this.colorOverride,
  });

  @override
  Widget build(BuildContext context) {
    final (iconData, defaultColor) = _resolve();
    return Icon(
      iconData,
      size: size,
      color: colorOverride ?? defaultColor,
    );
  }

  (IconData, Color) _resolve() {
    if (entry.isDir) {
      return (Icons.folder, const Color(0xFF5B7CFA));
    }
    if (entry.binary) {
      return (Icons.block, const Color(0xFFBBBBBB));
    }
    final ext = _extension(entry.name);
    if (_imageExtensions.contains(ext)) {
      return (Icons.image, const Color(0xFFA855F7));
    }
    if (_archiveExtensions.contains(ext)) {
      return (Icons.folder_zip_outlined, const Color(0xFFA0744B));
    }
    final codeColor = _codeColors[ext];
    if (codeColor != null) {
      return (Icons.code, codeColor);
    }
    return (Icons.description, const Color(0xFF888888));
  }

  static String _extension(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return '';
    return name.substring(dot + 1).toLowerCase();
  }
}
