import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart'
    show agentTabUnreadProvider;
import 'package:wanling_core/providers/conversation_provider.dart'
    show convByIdProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/theme/app_colors.dart';
import '../widgets/avatar.dart';
import '../widgets/unread_badge.dart';

/// 底栏编辑页:上半溢出项网格池 + 底部白条主排序区。
///
/// - 白条 = 底栏实时预览(可见项),整条可拖拽:换位 / 拖出白条放手=收进更多
///   (最少保留 1);固定项无减号(不可移除)
/// - 网格 = 溢出项池(含消息/万灵),agent 右上减号 unpin;池项拖到白条任意
///   位置放手 = 按落点计算插入槽位并扩容可见数
/// - 拖拽统一 move 语义(reorder:插入目标位其余顺移),实时持久化,「完成」仅 pop
class NavEditPage extends ConsumerStatefulWidget {
  const NavEditPage({super.key});

  @override
  ConsumerState<NavEditPage> createState() => _NavEditPageState();

  // 白条方块/网格方块尺寸(对齐主流 IM 参照:白条 48、网格 64 圆角 16)
  static const _barBox = 48.0;
  static const _gridBox = 64.0;
  static const _blue = Color(0xFF3370FF);
}

class _NavEditPageState extends ConsumerState<NavEditPage> {
  /// 白条整体 GlobalKey:拖拽放手时用落点全局坐标反算插入槽位。
  final GlobalKey _barKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(effectiveNavOrderProvider);
    final storedVisible = ref.watch(navVisibleCountProvider);
    // 白条 = 可见项(底栏实时预览);网格池 = 溢出项(含消息/万灵)。
    // 可见数由用户拖拽增减(白条项拖出白条减,池项拖回白条加),最少保留 1。
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
                backgroundColor: NavEditPage._blue,
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
                          _GridPoolItem(
                            key: ValueKey('grid-$id'),
                            tabId: id,
                            barKey: _barKey,
                            visibleCount: visibleCount,
                          ),
                      ],
                    ),
            ),
            _BottomBarPreview(
              barIds: barIds,
              showMore: showMore,
              visibleCount: visibleCount,
              barKey: _barKey,
            ),
          ],
        ),
      ),
    );
  }
}

/// 槽位显示名:固定项文案 / 会话 displayName / agent 名,缺数据回退原始 id。
String _slotName(WidgetRef ref, String tabId) {
  if (tabId == kNavTabMsg) return kNavTabMsgLabel;
  if (tabId == kNavTabWanling) return kNavTabWanlingLabel;
  final convId = navConvIdOf(tabId);
  if (convId != null) {
    return ref.watch(convByIdProvider(convId))?.displayName ?? tabId;
  }
  return ref.watch(agentByIdProvider(tabId))?.name ?? tabId;
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
      final convId = navConvIdOf(tabId);
      final String? avatarUrl;
      final int unread;
      if (convId != null) {
        final conv = ref.watch(convByIdProvider(convId));
        avatarUrl = conv?.displayAvatarUrl;
        unread = conv?.unreadCount ?? 0;
      } else {
        avatarUrl = ref.watch(agentByIdProvider(tabId))?.avatarUrl;
        unread = ref.watch(agentTabUnreadProvider(tabId));
      }
      // agent/会话:大圆角方形头像本体(与固定项图标方块同尺寸同圆角);
      // UnreadBadge 无 child 参数,减号压住头像右上角,均用 Stack + Positioned。
      inner = Stack(
        clipBehavior: Clip.none,
        children: [
          Avatar(
            name: name,
            url: avatarUrl,
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
          // 调用方已保证 name 语义:_MoreDropSlot 传「更多」,其余走 _slotName。
          child: Text(
            name,
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
  return Material(
    color: Colors.transparent,
    elevation: 6,
    borderRadius: BorderRadius.circular(box * 0.28),
    child: _SlotBox(tabId: tabId, box: box, name: _slotName(ref, tabId)),
  );
}

/// 上半网格池单格:溢出项(含固定项),可拖(拖到白条任意位置放手=按落点插入);
/// agent 带减号 unpin,固定项无减号(不可移除,可从池拖回白条恢复)。
class _GridPoolItem extends ConsumerWidget {
  const _GridPoolItem({
    super.key,
    required this.tabId,
    required this.barKey,
    required this.visibleCount,
  });

  final String tabId;
  final GlobalKey barKey;
  final int visibleCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isFixed = kNavFixedIds.contains(tabId);
    final name = _slotName(ref, tabId);
    final seqIdx = ref.watch(effectiveNavOrderProvider).indexOf(tabId);
    return LongPressDraggable<String>(
      data: tabId,
      delay: const Duration(milliseconds: 120),
      feedback: _dragFeedback(ref, tabId, NavEditPage._gridBox),
      // 拖拽结束:未落在任何 DragTarget 且放手点在白条内 → 按落点 x 计算插入槽位。
      onDragEnd: (details) {
        if (details.wasAccepted) return;
        final slotWidth = _barSlotWidth(barKey, visibleCount);
        if (slotWidth == null) return;
        if (!_barRectContains(barKey, details.offset)) return;
        final barLeft = _barLeft(barKey)!;
        final idx =
            ((details.offset.dx - barLeft) / slotWidth).floor().clamp(0, visibleCount);
        ref.read(navOrderProvider.notifier).reorder(tabId, idx);
        ref.read(navVisibleCountProvider.notifier).set(visibleCount + 1);
      },
      child: DragTarget<String>(
        // 仅接受池内来源项(池内换位);白条项有专门的「拖出白条=收进更多」语义。
        onWillAcceptWithDetails: (d) {
          final order = ref.read(effectiveNavOrderProvider);
          final from = order.indexOf(d.data);
          return d.data != tabId && from >= visibleCount;
        },
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
    required this.barKey,
  });

  final List<String> barIds;
  final bool showMore;
  final int visibleCount;
  final GlobalKey barKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return KeyedSubtree(
      key: const ValueKey('nav-edit-bar'),
      child: Container(
        key: barKey,
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
                child: _BarSlot(
                  tabId: id,
                  visibleCount: visibleCount,
                  barKey: barKey,
                ),
              ),
            if (showMore) _MoreDropSlot(visibleCount: visibleCount),
          ],
        ),
      ),
    );
  }
}

/// 白条槽:可拖可落(落点=该槽序列位,move 语义换位)。
/// 拖出白条(落点不在白条区域)放手 = 收进更多(最少保留 1)。
class _BarSlot extends ConsumerWidget {
  const _BarSlot({
    required this.tabId,
    required this.visibleCount,
    required this.barKey,
  });

  final String tabId;
  final int visibleCount;
  final GlobalKey barKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(effectiveNavOrderProvider);
    final name = _slotName(ref, tabId);
    final seqIdx = order.indexOf(tabId);
    return LongPressDraggable<String>(
      data: tabId,
      delay: const Duration(milliseconds: 120),
      feedback: _dragFeedback(ref, tabId, NavEditPage._barBox),
      // 拖拽结束:未落到任何 DragTarget(白条槽/更多格)且放手点在白条外
      // → 视为收进更多。落点在白条内但未命中(如拖回原位被自拒)= 无操作。
      onDragEnd: (details) {
        if (details.wasAccepted) return;
        if (visibleCount <= 1) return; // 底栏最少保留 1 个导航元素
        if (_barRectContains(barKey, details.offset)) return;
        ref.read(navOrderProvider.notifier).reorder(tabId, visibleCount - 1);
        ref.read(navVisibleCountProvider.notifier).set(visibleCount - 1);
      },
      child: DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != tabId,
        onAcceptWithDetails: (d) {
          ref.read(navOrderProvider.notifier).reorder(d.data, seqIdx);
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
            name: name,
          ),
        ),
      ),
    );
  }
}

/// 白条 GlobalKey 工具:放手点是否落在白条区域内 / 单槽宽(扣除水平 padding)。
bool _barRectContains(GlobalKey key, Offset globalPoint) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.attached) return false;
  final topLeft = box.localToGlobal(Offset.zero);
  return (topLeft & box.size).contains(globalPoint);
}

double? _barLeft(GlobalKey key) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.attached) return null;
  return box.localToGlobal(Offset.zero).dx;
}

/// 单槽宽 = (白条宽 - 水平 padding)/槽位数;槽位数 = 可见项 + (更多格)。
double? _barSlotWidth(GlobalKey key, int visibleCount) {
  final box = key.currentContext?.findRenderObject() as RenderBox?;
  if (box == null || !box.attached) return null;
  final slots = visibleCount + 1; // +「更多」格(即使 showMore=false 多算也 clamp 兜底)
  return (box.size.width - 16) / slots;
}
