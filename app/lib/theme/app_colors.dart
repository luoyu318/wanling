import 'package:flutter/material.dart';

/// 应用色板 token 集合。
///
/// **目的**：把散落在各页面的色值（#EDEDED / #999999 / #07C160 等）集中
/// 到一处，便于后续主题切换（升级到 ThemeExtension 时此处常量改为 getter）。
///
/// **本次范围**：先把 login / select_account / about 等子页面用到的基础色
/// 抽出。其他页面（ProfilePage / ChatPage 等）保留原内联色，后续逐步迁移。
///
/// **命名约定**：
/// - `pageBg*`：页面背景（按场景区分，不按主题明暗）
/// - `text*`：文字色（按层级 primary/secondary/hint）
/// - `accent*`：强调色（按钮、链接等）
/// - `danger`：危险操作色（删除、退出）
/// - `divider`：分割线
class AppColors {
  AppColors._(); // 仅静态常量

  // —— 页面背景 ——
  /// 登录前/独立页背景（白）：login / select_account / about
  static const Color pageBgLight = Color(0xFFFFFFFF);

  /// 主 APP 列表/卡片场景背景（浅灰）：profile / edit_profile / agent_detail
  static const Color pageBgStandard = Color(0xFFEDEDED);

  // —— AppBar ——
  /// AppBar 背景统一白
  static const Color appBarBg = Color(0xFFFFFFFF);

  /// AppBar 文字色统一深黑
  static const Color appBarFg = Color(0xFF111111);

  // —— 文字层级 ——
  /// 标题/主文字
  static const Color textPrimary = Color(0xFF111111);

  /// 正文（SettingsTile label / 普通内容）
  static const Color textBody = Color(0xFF333333);

  /// 副文字（提示、说明、时间戳）
  static const Color textSecondary = Color(0xFF999999);

  /// 输入框 placeholder
  static const Color textHint = Color(0xFFBBBBBB);

  // —— 强调色 ——
  /// 品牌主色绿（主操作按钮、Logo accent）
  static const Color accentGreen = Color(0xFF07C160);

  /// 链接蓝（编辑资料「点击更换头像」等）
  static const Color linkBlue = Color(0xFF5B8BF7);

  // —— 状态色 ——
  /// 危险操作（删除、退出登录）
  static const Color danger = Color(0xFFFA5151);

  // —— 分割线 ——
  static const Color divider = Color(0xFFE4E4E4);
}
