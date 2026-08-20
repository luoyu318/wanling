import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 聊天区右侧详情侧栏开关(Task 5 定义,Task 7 接面板内容)。
/// false = 收起(默认),true = 展开。由 ChatAppBar「详情」按钮 toggle。
final detailPanelOpenProvider = StateProvider<bool>((ref) => false);

/// 详情侧栏当前 tab:信息(默认)/ 变更。
enum DetailPanelTab { info, changes }

/// tab 选中态:面板收起时保留,重开回到上次 tab。
final detailPanelTabProvider =
    StateProvider<DetailPanelTab>((ref) => DetailPanelTab.info);
