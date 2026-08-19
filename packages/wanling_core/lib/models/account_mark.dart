import 'package:flutter/foundation.dart';

/// 账号视觉标记:颜色索引 + 可选 emoji。
///
/// colorIndex 取自固定调色板(AccountPalette.colors),存索引而非 Color 值,
/// 序列化稳定且便于将来换肤。emoji 可与颜色共存或单用。
@immutable
class AccountMark {
  final int colorIndex;
  final String? emoji;

  const AccountMark({required this.colorIndex, this.emoji});

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{'colorIndex': colorIndex};
    if (emoji != null) m['emoji'] = emoji;
    return m;
  }

  factory AccountMark.fromJson(Map<String, dynamic> json) => AccountMark(
        colorIndex: json['colorIndex'] as int,
        emoji: json['emoji'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountMark &&
          colorIndex == other.colorIndex &&
          emoji == other.emoji;

  @override
  int get hashCode => Object.hash(colorIndex, emoji);
}
