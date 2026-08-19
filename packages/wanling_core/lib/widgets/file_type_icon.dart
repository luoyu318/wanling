import 'package:flutter/material.dart';

class _FileTypeColors {
  final Color bg;
  final Color fg;
  final String label;
  const _FileTypeColors(this.bg, this.fg, this.label);
}

const _mimeMap = <String, _FileTypeColors>{
  'application/pdf': _FileTypeColors(Color(0xFFFEE2E2), Color(0xFFDC2626), 'PDF'),
  'application/msword': _FileTypeColors(Color(0xFFDBEAFE), Color(0xFF2563EB), 'W'),
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document': _FileTypeColors(Color(0xFFDBEAFE), Color(0xFF2563EB), 'W'),
  'application/vnd.ms-excel': _FileTypeColors(Color(0xFFD1FAE5), Color(0xFF16A34A), 'X'),
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet': _FileTypeColors(Color(0xFFD1FAE5), Color(0xFF16A34A), 'X'),
  'application/vnd.ms-powerpoint': _FileTypeColors(Color(0xFFFEF3C7), Color(0xFFD97706), 'P'),
  'application/vnd.openxmlformats-officedocument.presentationml.presentation': _FileTypeColors(Color(0xFFFEF3C7), Color(0xFFD97706), 'P'),
  'application/zip': _FileTypeColors(Color(0xFFF3E8FF), Color(0xFF9333EA), 'Z'),
  'application/x-zip-compressed': _FileTypeColors(Color(0xFFF3E8FF), Color(0xFF9333EA), 'Z'),
  'text/plain': _FileTypeColors(Color(0xFFF1F5F9), Color(0xFF475569), 'T'),
  'text/markdown': _FileTypeColors(Color(0xFFF1F5F9), Color(0xFF475569), 'T'),
  'text/csv': _FileTypeColors(Color(0xFFF1F5F9), Color(0xFF475569), 'T'),
};

const _fallbackColors = _FileTypeColors(Color(0xFFF1F5F9), Color(0xFF475569), '?');

/// 彩色文件类型图标。44x44 默认尺寸，圆角 10，彩色背景+缩写文字。
/// 配色按 mime_type 映射：PDF 红 / Word 蓝 / Excel 绿 / PPT 橙 / ZIP 紫 / 文本 灰 / 其他 灰?
class FileTypeIcon extends StatelessWidget {
  final String mimeType;
  final double size;

  const FileTypeIcon({super.key, required this.mimeType, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final colors = _mimeMap[mimeType] ?? _fallbackColors;
    return Container(
      width: size,
      height: size,
      constraints: BoxConstraints(maxWidth: size, maxHeight: size),
      decoration: BoxDecoration(
        color: colors.bg,
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        colors.label,
        style: TextStyle(
          fontSize: size * 0.34,
          fontWeight: FontWeight.w700,
          color: colors.fg,
        ),
      ),
    );
  }
}
