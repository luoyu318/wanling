import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/providers/chat_provider.dart';

/// 本地存储异常提示 banner。
///
/// 监听 [localStoreHealthProvider]:degraded(true)时显示「本地存储异常」。
/// 触发条件:`_persistToStore` 连续失败超阈值(磁盘满 / DB 损坏等)。
/// 用户感知 = 知道部分消息可能没持久化,下次离线打开看不到。
///
/// 与 [ConnectionBanner] 区别:
/// - ConnectionBanner:网络断,橙色,云朵图标
/// - LocalStoreBanner:本地存储异常,琥珀色,存储图标
///
/// 不去抖:store failure 是持续状态,只在跨阈值时 emit 一次 true,
/// 恢复时 emit false。无连接切换那种瞬时抖动。
class LocalStoreBanner extends ConsumerWidget {
  const LocalStoreBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final health = ref.watch(localStoreHealthProvider);
    final degraded = health.valueOrNull == true;
    if (!degraded) return const SizedBox.shrink();
    return MaterialBanner(
      content: const Row(
        children: [
          Icon(Icons.storage, size: 16, color: Colors.white),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              '本地存储异常,部分消息可能未保存',
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
      backgroundColor: const Color(0xFFFFA000),
      actions: const [SizedBox.shrink()],
    );
  }
}
