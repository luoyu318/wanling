import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart'
    show agentTabUnreadProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/theme/app_colors.dart';
import '../widgets/avatar.dart';
import '../widgets/unread_badge.dart';

/// 底栏编辑页:上半溢出 agent 网格池 + 底部白条主排序区。
///
/// - 白条 = 完整底栏实时预览,任意槽(除「更多」格)可长按拖拽换位,
///   固定项(msg/wanling)可拖可落但无减号(不可移除)
/// - 网格 = 溢出 agent 池,方块右上减号 unpin;与白条跨区拖拽 = 可见性互换
/// - 拖拽统一 move 语义(reorder:插入目标位其余顺移),实时持久化,「完成」仅 pop
class NavEditPage extends ConsumerWidget {
  const NavEditPage({super.key});

  // 白条方块/网格方块尺寸(对齐主流 IM 参照:白条 48、网格 64 圆角 16)
  static const _barBox = 48.0;
  static const _gridBox = 64.0;
  static const _blue = Color(0xFF3370FF);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(effectiveNavOrderProvider);
    final agents = [
      for (final id in order) if (!kNavFixedIds.contains(id)) id
    ];
    final showMore = agents.length >= 4;
    final visibleAgentCount = showMore ? 2 : 3;
    final barIds = order.take(2 + visibleAgentCount).toList();
    final overflowIds = agents.skip(visibleAgentCount).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF7F7F7),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '关闭',
          onPressed: () => Navigator.pop(context),
        ),
        centerTitle: true,
        // 标题不能叫「更多」:与白条「更多」格文案冲突(widget 测试按文案定位)。
        title: const Text('编辑底栏',
            style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton(
              style: TextButton.styleFrom(
                backgroundColor: _blue,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                shape: const StadiumBorder(),
              ),
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: overflowIds.isEmpty
                  ? const SizedBox.shrink()
                  : GridView.count(
                      padding: const EdgeInsets.all(16),
                      crossAxisCount: 4,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 8,
                      childAspectRatio: 0.72,
                      children: [
                        for (final id in overflowIds)
                          _GridPoolItem(key: ValueKey('grid-$id'), agentId: id),
                      ],
                    ),
            ),
            _BottomBarPreview(barIds: barIds, showMore: showMore),
          ],
        ),
      ),
    );
  }
}

/// 槽位内容:固定项图标方块 / 「更多」图标方块 / agent 头像方块。
/// 减号仅在显式传入 onUnpin 时出现。
class _SlotBox extends ConsumerWidget {
  const _SlotBox({
    required this.tabId,
    required this.box,
    required this.name,
    this.onUnpin,
  });

  final String tabId;
  final double box;
  final String name;
  final VoidCallback? onUnpin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const moreId = '__more__';
    final isFixed = kNavFixedIds.contains(tabId);
    final isMore = tabId == moreId;
    final Widget inner;
    if (isFixed || isMore) {
      // 固定项/「更多」格:白底图标方块(纯展示,不查 agent)。
      final icon = isMore
          ? Icons.apps
          : (tabId == kNavTabMsg
              ? Icons.chat_bubble_outline
              : Icons.auto_awesome_outlined);
      inner = Container(
        width: box,
        height: box,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(box * 0.28),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: box * 0.5, color: AppColors.textSecondary),
      );
    } else {
      final agent = ref.watch(agentByIdProvider(tabId));
      final unread = ref.watch(agentTabUnreadProvider(tabId));
      // UnreadBadge 无 child 参数,用 Stack + Positioned 叠右上角红标。
      inner = Stack(
        clipBehavior: Clip.none,
        children: [
          Avatar(
            name: name,
            url: agent?.avatarUrl,
            size: box * 0.72,
            radius: box * 0.36,
          ),
          if (unread > 0)
            Positioned(
              top: -4,
              right: -4,
              child: UnreadBadge(count: unread),
            ),
        ],
      );
    }

    final labeled = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        inner,
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: box + 24),
          child: Text(
            isMore
                ? '更多'
                : isFixed
                    ? (tabId == kNavTabMsg ? '消息' : '万灵')
                    : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary),
          ),
        ),
      ],
    );

    if (onUnpin == null) return labeled;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        labeled,
        Positioned(
          top: -6,
          right: -6,
          child: GestureDetector(
            key: ValueKey('unpin-$tabId'),
            onTap: onUnpin,
            child: Container(
              width: 20,
              height: 20,
              decoration: const BoxDecoration(
                  color: AppColors.danger, shape: BoxShape.circle),
              alignment: Alignment.center,
              child:
                  const Icon(Icons.remove, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }
}

/// 拖拽 feedback:放大方块 + 投影。
/// 仅在 build 期间被引用(闭包捕获),此处 ref.watch 合法。
Widget _dragFeedback(WidgetRef ref, String tabId, double box) {
  final agent = kNavFixedIds.contains(tabId)
      ? null
      : ref.watch(agentByIdProvider(tabId));
  return Material(
    color: Colors.transparent,
    elevation: 6,
    borderRadius: BorderRadius.circular(box * 0.28),
    child: _SlotBox(tabId: tabId, box: box, name: agent?.name ?? tabId),
  );
}

/// 上半网格池单格:溢出 agent,可拖(进白条变可见)、可收(白条 agent 落入)、减号 unpin。
class _GridPoolItem extends ConsumerWidget {
  const _GridPoolItem({super.key, required this.agentId});

  final String agentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agent = ref.watch(agentByIdProvider(agentId));
    final name = agent?.name ?? agentId;
    final seqIdx =
        ref.watch(effectiveNavOrderProvider).indexOf(agentId);
    return LongPressDraggable<String>(
      data: agentId,
      delay: const Duration(milliseconds: 120),
      feedback: _dragFeedback(ref, agentId, NavEditPage._gridBox),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != agentId,
        onAcceptWithDetails: (d) => ref
            .read(navOrderProvider.notifier)
            .reorder(d.data, seqIdx),
        builder: (context, candidate, _) => _SlotBox(
          tabId: agentId,
          box: NavEditPage._gridBox,
          name: name,
          onUnpin: () => ref.read(navOrderProvider.notifier).unpin(agentId),
        ),
      ),
    );
  }
}

/// 底部白条主排序区:序列前缀(固定项+可见 agent)+「更多」格(不可拖不可落)。
class _BottomBarPreview extends ConsumerWidget {
  const _BottomBarPreview({required this.barIds, required this.showMore});

  final List<String> barIds;
  final bool showMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          for (final id in barIds)
            Expanded(
              child: _BarSlot(tabId: id),
            ),
          if (showMore)
            const Expanded(
              child: _SlotBox(tabId: '__more__', box: NavEditPage._barBox, name: '更多'),
            ),
        ],
      ),
    );
  }
}

/// 白条槽:可拖可落。落点 = 该槽在序列中的位置(reorder move 语义)。
class _BarSlot extends ConsumerWidget {
  const _BarSlot({required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(effectiveNavOrderProvider);
    final agent = kNavFixedIds.contains(tabId)
        ? null
        : ref.watch(agentByIdProvider(tabId));
    final seqIdx = order.indexOf(tabId);
    return LongPressDraggable<String>(
      data: tabId,
      delay: const Duration(milliseconds: 120),
      feedback: _dragFeedback(ref, tabId, NavEditPage._barBox),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != tabId,
        onAcceptWithDetails: (d) =>
            ref.read(navOrderProvider.notifier).reorder(d.data, seqIdx),
        builder: (context, candidate, _) => Opacity(
          opacity: candidate.isNotEmpty ? 0.5 : 1,
          child: _SlotBox(
            tabId: tabId,
            box: NavEditPage._barBox,
            name: agent?.name ?? tabId,
          ),
        ),
      ),
    );
  }
}
