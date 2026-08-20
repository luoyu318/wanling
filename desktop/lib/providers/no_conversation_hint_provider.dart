import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 万灵页点卡片但该 agent 无会话时写入的提示文案。
/// 消息页空态处消费显示；切到会话或离开消息页时清除。
final noConversationHintProvider = StateProvider<String?>((ref) => null);
