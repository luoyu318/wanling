import 'package:flutter/widgets.dart';

/// iconfont 图标字体封装（iconfont.cn,项目 Wanling）。
///
/// 字形 unicode 见 `fonts/iconfont.ttf`（glyphs）:
/// - think=e6de 思考 / deepThink=e622 深度思考 / search=e62f 搜索
/// - explore=e600 WebFetch/探索 / shell=e666 shell / edit=e62c 编辑
///
/// 聚合卡工具类别图标统一走这里,避免魔法字符串散落各 renderer。
class IconFont {
  IconFont._();

  static const _family = 'iconfont';

  /// 思考（reasoning 思考块）。
  static const String think = '\u{e6de}';

  /// 深度思考。
  static const String deepThink = '\u{e622}';

  /// 搜索（探索组 grep/glob/read）。
  static const String search = '\u{e62f}';

  /// WebFetch / 网络探索。
  static const String explore = '\u{e600}';

  /// shell（命令组 bash）。
  static const String shell = '\u{e666}';

  /// 编辑（编辑组 edit/write）。
  static const String edit = '\u{e62c}';

  /// 渲染单个 iconfont 字形。
  ///
  /// [color] 默认中性灰（无边框无背景的纯文字行图标色）。
  static Text icon(String glyph, {double size = 13, Color color = const Color(0xFF999999)}) {
    return Text(
      glyph,
      style: TextStyle(fontFamily: _family, fontSize: size, color: color, height: 1),
    );
  }
}
