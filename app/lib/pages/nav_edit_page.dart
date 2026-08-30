import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart'
    show agentTabUnreadProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/theme/app_colors.dart';
import '../widgets/avatar.dart';
import '../widgets/unread_badge.dart';

/// 底栏编辑页:上半溢出项网格池 + 底部白条主排序区。
///
/// - 白条 = 底栏实时预览(序列前缀,固定项/agent 混合),任意槽(除「更多」格)
///   可长按拖拽换位;固定项无减号(不可移除)
/// - 网格 = 溢出项池(含消息/万灵),agent 右上减号 unpin;与白条跨区拖拽 =
///   可见性互换(拖入「更多」的固定项仍可点选可达)
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
    final storedVisible = ref.watch(navVisibleCountProvider);
    // 白条 = 可见项(底栏实时预览);网格池 = 溢出项(含消息/万灵)。
    // 可见数由用户拖拽增减(拖项进「更多」格减,池项拖回白条加),最少保留 1。
    final visibleCount = resolveVisibleCount(storedVisible, order.length);
    final showMore = order.length > visibleCount;
    final barIds = order.take(visibleCount).toList();
    final overflowIds = order.skip(visibleCount).toList();

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
                          _GridPoolItem(key: ValueKey('grid-$id'), tabId: id),
                      ],
                    ),
            ),
            _BottomBarPreview(
                barIds: barIds, showMore: showMore, visibleCount: visibleCount),
          ],
        ),
      ),
    );
  }
}

/// 槽位内容:固定项图标方块 / 「更多」图标方块 / agent 大圆角方形头像。
/// 减号仅在显式传入 onUnpin 时出现(固定项无减号,不可移除)。
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
          borderRadius: BorderRadius.circular(box * 0.25),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: box * 0.5, color: AppColors.textSecondary),
      );
    } else {
      final agent = ref.watch(agentByIdProvider(tabId));
      final unread = ref.watch(agentTabUnreadProvider(tabId));
      // agent:大圆角方形头像本体(与固定项图标方块同尺寸同圆角);
      // UnreadBadge 无 child 参数,减号压住头像右上角,均用 Stack + Positioned。
      inner = Stack(
        clipBehavior: Clip.none,
        children: [
          Avatar(
            name: name,
            url: agent?.avatarUrl,
            size: box,
            radius: box * 0.25,
          ),
          if (unread > 0)
            Positioned(
              top: -4,
              right: -4,
              child: UnreadBadge(count: unread),
            ),
          if (onUnpin != null)
            Positioned(
              top: -5,
              right: -5,
              child: GestureDetector(
                key: ValueKey('unpin-$tabId'),
                onTap: onUnpin,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                      color: AppColors.danger, shape: BoxShape.circle),
                  alignment: Alignment.center,
                  child: const Icon(Icons.remove,
                      size: 14, color: Colors.white),
                ),
              ),
            ),
        ],
      );
    }

    return Column(
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

/// 上半网格池单格:溢出项(含固定项),可拖(进白条变可见)、可收(白条项落入);
/// agent 带减号 unpin,固定项无减号(不可移除,可从池拖回白条恢复)。
class _GridPoolItem extends ConsumerWidget {
  const _GridPoolItem({super.key, required this.tabId});

  final String tabId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFixed = kNavFixedIds.contains(tabId);
    final agent = isFixed ? null : ref.watch(agentByIdProvider(tabId));
    final name = isFixed
        ? (tabId == kNavTabMsg ? '消息' : '万灵')
        : (agent?.name ?? tabId);
    final seqIdx = ref.watch(effectiveNavOrderProvider).indexOf(tabId);
    return LongPressDraggable<String>(
      data: tabId,
      delay: const Duration(milliseconds: 120),
      feedback: _dragFeedback(ref, tabId, NavEditPage._gridBox),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != tabId,
        onAcceptWithDetails: (d) =>
            ref.read(navOrderProvider.notifier).reorder(d.data, seqIdx),
        builder: (context, candidate, _) => _SlotBox(
          tabId: tabId,
          box: NavEditPage._gridBox,
          name: name,
          onUnpin: isFixed
              ? null
              : () => ref.read(navOrderProvider.notifier).unpin(tabId),
        ),
      ),
    );
  }
}

/// 「更多」格:白底格子图标;接收白条项拖入 = 收进更多(可见数-1,最少保留 1)。
class _MoreDropSlot extends ConsumerWidget {
  const _MoreDropSlot({required this.visibleCount});

  final int visibleCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Expanded(
      child: DragTarget<String>(
        // 仅接受白条(可见)来源项,且底栏最少保留 1 个导航元素。
        onWillAcceptWithDetails: (d) {
          final order = ref.read(effectiveNavOrderProvider);
          if (visibleCount <= 1) return false;
          final from = order.indexOf(d.data);
          return from >= 0 && from < visibleCount;
        },
        onAcceptWithDetails: (d) {
          ref.read(navOrderProvider.notifier).reorder(d.data, visibleCount - 1);
          ref.read(navVisibleCountProvider.notifier).set(visibleCount - 1);
        },
        builder: (context, candidate, _) => Opacity(
          opacity: candidate.isNotEmpty ? 0.6 : 1,
          child: const _SlotBox(
            tabId: '__more__',
            box: NavEditPage._barBox,
            name: '更多',
          ),
        ),
      ),
    );
  }
}

/// 底部白条主排序区:可见项(底栏预览)+「更多」格(可接收白条项=收进更多)。
class _BottomBarPreview extends ConsumerWidget {
  const _BottomBarPreview({
    required this.barIds,
    required this.showMore,
    required this.visibleCount,
  });

  final List<String> barIds;
  final bool showMore;
  final int visibleCount;

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
              child: _BarSlot(tabId: id, visibleCount: visibleCount),
            ),
          if (showMore) _MoreDropSlot(visibleCount: visibleCount),
        ],
      ),
    );
  }
}

/// 白条槽:可拖可落。落点 = 该槽在序列中的位置(reorder move 语义);
/// 池项拖入 = 进可见区并扩容可见数(≤4)。
class _BarSlot extends ConsumerWidget {
  const _BarSlot({required this.tabId, required this.visibleCount});

  final String tabId;
  final int visibleCount;

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
        onAcceptWithDetails: (d) {
          ref
              .read(navOrderProvider.notifier)
              .reorder(d.data, seqIdx);
          // 来源在池(可见区之外)则本次落入扩容可见数。
          final from = order.indexOf(d.data);
          if (from >= visibleCount) {
            ref.read(navVisibleCountProvider.notifier).set(visibleCount + 1);
          }
        },
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
