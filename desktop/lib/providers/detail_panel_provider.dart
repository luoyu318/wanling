import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 聊天区右侧详情侧栏开关(Task 5 定义,Task 7 接面板内容)。
/// false = 收起(默认),true = 展开。由 ChatAppBar「详情」按钮 toggle。
final detailPanelOpenProvider = StateProvider<bool>((ref) => false);
