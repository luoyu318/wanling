import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 万灵详情页 CTA「进入会话」→ 壳层二级 session 列表的联动脉冲:
/// AgentDetailPage 写入 agent id,DesktopShell 会话卡片宿主 listen
/// 消费(切二级列表)后立即回置 null(单向脉冲,防残留误触发)。
final openAgentSessionsProvider = StateProvider<String?>((ref) => null);
