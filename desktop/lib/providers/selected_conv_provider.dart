import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 当前选中的会话 id(桌面双栏布局左列选中项)。
/// null 表示未选中,右侧聊天区显示占位。聊天页(Task 5)消费。
final selectedConvProvider = StateProvider<String?>((ref) => null);
