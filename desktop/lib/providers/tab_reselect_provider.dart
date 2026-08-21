import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 「重复点击当前 tab 回一级列表」脉冲(仿 openAgentSessionsProvider 模式)。
///
/// 背景:NavRail 点击当前 tab 时 context.go 无路由变化,左栏二级 session
/// 列表(_ConversationCardHostState._sessionsAgentId 自持)不会回一级。
/// NavRail 在选中态点击时写入 tab 路由名(如 '/messages'),壳层监听后
/// 清二级状态并回置 null(消费后清零,防残留)。
final tabReselectProvider = StateProvider<String?>((ref) => null);
