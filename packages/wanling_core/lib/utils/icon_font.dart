import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// iconfont 图标字体封装（iconfont.cn,项目 Wanling）。
///
/// 字形 unicode 见 `fonts/iconfont.ttf`（glyphs）:
/// - think=e6de 思考 / deepThink=e622 深度思考 / search=e62f 搜索
/// - explore=e600 WebFetch/探索 / shell=e666 shell / edit=e62c 编辑
/// - permission=fbb8 权限 / question=e604 问答 / tools=e882 工具
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

  /// 权限（权限审批卡）。
  static const String permission = '\u{fbb8}';

  /// 问答（选择题卡）。
  static const String question = '\u{e604}';

  /// 工具（工具折叠组，MCP 等未知工具名）。
  static const String tools = '\u{e882}';

  /// 各字形在 em 框内的墨迹占比（fontTools 实测 iconfont.ttf 包围盒 ÷ unitsPerEm）。
  ///
  /// 字形间占满程度差异大（tools .97 满框 vs shell 高只有 .625），同字号视觉
  /// 大小不一；折叠行等混排场景用 [normalizedSize] 归一。
  static const Map<String, ({double w, double h})> glyphMetrics = {
    think: (w: 0.837, h: 0.816),
    deepThink: (w: 0.750, h: 0.667),
    search: (w: 0.834, h: 0.834),
    explore: (w: 0.868, h: 0.867),
    shell: (w: 0.750, h: 0.625),
    edit: (w: 0.699, h: 0.699),
    permission: (w: 0.761, h: 0.843),
    question: (w: 0.687, h: 0.875),
    tools: (w: 0.969, h: 0.967),
  };

  /// 视觉归一字号：让不同字形的墨迹包围盒面积相等。
  ///
  /// [targetVisual] 为归一目标「等效方边长」（默认 12.5px，接近 15 号下
  /// search 字形的观感）。字号 = target / √(w占比 × h占比)。
  /// 未知字形按中等占满率 0.83 兜底。
  static double normalizedSize(String glyph, {double targetVisual = 12.5}) {
    final m = glyphMetrics[glyph];
    final area = m != null ? m.w * m.h : 0.83 * 0.83;
    return targetVisual / math.sqrt(area);
  }

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
