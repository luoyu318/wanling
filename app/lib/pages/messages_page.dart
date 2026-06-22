import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/conversation.dart';
import '../providers/conversation_provider.dart';
import '../router_helpers.dart';
import '../utils/snackbar.dart';
import '../widgets/avatar.dart';

/// 消息列表页（IM 风格）。
///
/// 设计要点：
/// - ConsumerStatefulWidget：用 initState 在首次进入时触发 load（拉取最新列表）。
/// - RefreshIndicator：空状态也要能下拉刷新，所以空内容用 ListView 包裹。
/// - 会话栏:padding vertical 12,分割线 0.5px margin-left 60(头像右侧起)。
/// - 置顶会话:浅灰背景 #E5E5E5。
/// - 长按弹位置菜单(置顶/取消置顶 + 删除)。
class MessagesPage extends ConsumerStatefulWidget {
  const MessagesPage({super.key});

  @override
  ConsumerState<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends ConsumerState<MessagesPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 用 microtask 延后一帧执行：initState 内直接 ref.read 在某些 lint 规则下会告警，
    // 且 build 阶段尚未完成时触发异步状态变更更稳妥。
    Future.microtask(() => ref.read(conversationProvider.notifier).load());
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 必须调
    final list = ref.watch(conversationProvider);

    // AppBar 移到 HomePage 共享管理，这里直接返回 body 内容。
    // 背景白底让分割线清晰可见。
    return ColoredBox(
      color: Colors.white,
      child: RefreshIndicator(
        onRefresh: () => ref.read(conversationProvider.notifier).load(),
        child: list.isEmpty
            ? _EmptyState(
                onRetry:
                    () => ref.read(conversationProvider.notifier).load(),
              )
            // 不用 ListView.separated：分割线在 _ConvTile 内部画，
            // 这样最后一条 tile 也有底部分割线（separated 只画 item 之间）。
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final c = list[i];
                  final nextIsPinned =
                      i + 1 < list.length && list[i + 1].isPinned;
                  return _ConvTile(
                    conv: c,
                    key: ValueKey('conv_${c.id}'),
                    nextIsPinned: nextIsPinned,
                    onTap: () => context.push(chatRoute(c.id, c.agent.id)),
                    onLongPressStart: (details) =>
                        _showConvMenu(context, details.globalPosition, c),
                  );
                },
              ),
      ),
    );
  }

  /// 长按会话弹位置菜单(置顶/取消置顶 + 删除)。
  /// [globalPos] 是长按按下处的全局坐标，菜单左上角对齐到该坐标。
  /// 用 PageRouteBuilder(Duration.zero) 代替 showMenu 取消弹出动画。
  Future<void> _showConvMenu(
      BuildContext context, Offset globalPos, Conversation conv) async {
    final overlay = Navigator.of(context).overlay!;
    final overlayBox =
        overlay.context.findRenderObject() as RenderBox;
    final overlaySize = overlayBox.size;
    // global → overlay 本地坐标，避免状态栏/导航栏偏移
    final local = overlayBox.globalToLocal(globalPos);

    const menuWidth = 140.0;
    const itemHeight = 48.0;
    final menuHeight = itemHeight * 2;

    // 边界保护：菜单不溢出右/下，留 8px 安全间距
    final left = (local.dx + menuWidth > overlaySize.width - 8)
        ? overlaySize.width - menuWidth - 8
        : local.dx;
    final top = (local.dy + menuHeight > overlaySize.height - 8)
        ? overlaySize.height - menuHeight - 8
        : local.dy;

    final selected = await Navigator.of(context).push<String>(
      PageRouteBuilder<String>(
        opaque: false,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (ctx, _, _) {
          return GestureDetector(
            // 全屏吃事件；点空白处关闭
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.pop(ctx),
            child: Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  child: Material(
                    color: Colors.transparent,
                    child: Container(
                      width: menuWidth,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        boxShadow: [
                          const BoxShadow(
                            color: Color(0x26000000), // alpha≈15%
                            blurRadius: 12,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _menuItem(
                            label: conv.isPinned ? '取消置顶' : '置顶',
                            color: const Color(0xFF111111),
                            onTap: () => Navigator.pop(
                                ctx, conv.isPinned ? 'unpin' : 'pin'),
                          ),
                          _menuItem(
                            label: '删除会话',
                            color: const Color(0xFFFA5151),
                            onTap: () => Navigator.pop(ctx, 'hide'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    if (selected == null) return;
    if (!mounted) return;

    if (selected == 'pin' || selected == 'unpin') {
      try {
        if (selected == 'pin') {
          await ref.read(conversationProvider.notifier).pin(conv.id);
        } else {
          await ref.read(conversationProvider.notifier).unpin(conv.id);
        }
      } catch (_) {
        if (mounted) {
          showAppSnackBar(context, '操作失败,请重试', type: SnackBarType.error);
        }
      }
    } else if (selected == 'hide') {
      final confirmed = await _confirmHide(context);
      if (confirmed != true) return;
      if (!mounted) return;
      try {
        await ref.read(conversationProvider.notifier).hide(conv.id);
      } catch (_) {
        if (mounted) {
          showAppSnackBar(context, '删除失败,请重试', type: SnackBarType.error);
        }
      }
    }
  }

  /// 删除确认 dialog。
  Future<bool?> _confirmHide(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除该会话?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
        content: const Text(
          '聊天记录将保留,有新消息时会话自动恢复。',
          style: TextStyle(fontSize: 12, color: Color(0xFF999999)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFFF0F0F0),
              child: const Text('取消',
                  style: TextStyle(color: Color(0xFF666666))),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: const Color(0xFFFA5151),
              child:
                  const Text('删除', style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 长按菜单的单项。
Widget _menuItem({
  required String label,
  required Color color,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    child: Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 14),
      ),
    ),
  );
}

/// 空状态。用 ListView 包裹是为了让 RefreshIndicator 在空列表也能下拉。
class _EmptyState extends StatelessWidget {
  final VoidCallback onRetry;
  const _EmptyState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: const [
        SizedBox(height: 200),
        Center(
          child: Text(
            '暂无对话，去和 Agent 聊聊吧',
            style: TextStyle(color: Color(0xFF999999)),
          ),
        ),
      ],
    );
  }
}

/// 单个会话列表项:头像 + 名字 + 最后一条预览 + 时间。
/// 置顶会话背景 #EDEDED,普通会话白底。
/// 分割线在 tile 内部底部，每条 tile（包括最后一条）都画。
/// 按下（点击/长按）时背景变更反馈色，松开恢复；长按触发 HapticFeedback。
class _ConvTile extends StatefulWidget {
  final Conversation conv;
  final bool nextIsPinned; // 下一条 tile 是否置顶（决定分割线颜色档位）
  final VoidCallback onTap;
  final Future<void> Function(LongPressStartDetails details) onLongPressStart;
  const _ConvTile({
    super.key,
    required this.conv,
    required this.nextIsPinned,
    required this.onTap,
    required this.onLongPressStart,
  });

  @override
  State<_ConvTile> createState() => _ConvTileState();
}

class _ConvTileState extends State<_ConvTile> {
  bool _isPressed = false;
  Offset? _downPos; // 记录按下位置，检测滑动距离
  bool _inLongPressMenu = false; // 长按菜单弹出期间，不响应滑动归位

  void _setPressed(bool v) {
    if (_isPressed == v) return;
    setState(() => _isPressed = v);
  }

  /// 简单的时间格式化：今天显示 HH:mm，否则显示 MM-dd。
  String _formatTime(DateTime t) {
    final local = t.toLocal();
    final now = DateTime.now();
    if (local.year == now.year &&
        local.month == now.month &&
        local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
    }
    return '${local.month}-${local.day}';
  }

  @override
  Widget build(BuildContext context) {
    final conv = widget.conv;
    // 分割线颜色三档：
    //   非置顶 → #E4E4E4
    //   置顶 + 下一条也置顶 → #D2D2D2
    //   置顶 + 下一条非置顶（或没有下一条，即置顶组末尾）→ #D6D6D6
    final dividerColor = !conv.isPinned
        ? const Color(0xFFE4E4E4)
        : (widget.nextIsPinned
            ? const Color(0xFFD2D2D2)
            : const Color(0xFFD6D6D6));
    // 分割线区域背景：置顶时与 tile 同色（消除白缝），非置顶时透到 Scaffold 白底
    // 注意：按下时分割线区域不变色，仅 tile 内容区有反馈
    final dividerBg =
        conv.isPinned ? const Color(0xFFEDEDED) : Colors.white;
    // tile 背景：按下时切到深一档（普通 #EDEDED / 置顶 #D6D6D6），松开恢复
    final tileBg = _isPressed
        ? (conv.isPinned
            ? const Color(0xFFD6D6D6)
            : const Color(0xFFEDEDED))
        : (conv.isPinned
            ? const Color(0xFFEDEDED)
            : Colors.white);

    // Listener 包最外层：onPointerDown 绕过 gesture arena，按下立即变色
    // （InkWell.onTapDown 要等 arena 解决 tap vs long-press，快速点击看不到反馈）。
    return Listener(
      onPointerDown: (e) {
        _downPos = e.position;
        _setPressed(true);
      },
      // 滑动超过 8px 视为滚动，立即归位避免背景色卡住（长按菜单期间不响应）
      onPointerMove: (e) {
        if (_inLongPressMenu) return;
        if (_downPos != null &&
            (e.position - _downPos!).distance > 8) {
          _setPressed(false);
        }
      },
      // 长按菜单弹出后用户手指抬起不应归位（菜单还没关）。
      // 菜单关闭（onLongPressStart 的 await 返回）才在 finally 块归位。
      onPointerUp: (_) {
        _downPos = null;
        if (_inLongPressMenu) return;
        _setPressed(false);
      },
      onPointerCancel: (_) {
        _downPos = null;
        if (_inLongPressMenu) return;
        _setPressed(false);
      },
      child: GestureDetector(
        onLongPressStart: (details) async {
          HapticFeedback.selectionClick();
          // long press wins arena 后 InkWell.onTapCancel 会清 _isPressed，
          // 这里设回 true 覆盖，保持长按期间按下色。两次 setState 同帧合并无闪烁。
          _setPressed(true);
          _inLongPressMenu = true;
          try {
            // 等菜单关闭（_showConvMenu 的 Future），菜单消失后才归位
            await widget.onLongPressStart(details);
          } finally {
            _inLongPressMenu = false;
            if (mounted) _setPressed(false);
          }
        },
        child: InkWell(
          onTap: widget.onTap,
          // tap 反馈归位由 Listener.onPointerUp 处理（更早、更可靠）
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
        child: Column(
          children: [
            Container(
              color: tileBg,
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              // crossAxisAlignment.start 让时间 Text 顶部和昵称 Text 顶部对齐
              // （Row 默认 center 会让时间垂直居中到头像中线）。
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Avatar(
                    name: conv.agent.name,
                    url: conv.agent.avatarUrl,
                    size: 48,
                    unreadCount: conv.unreadCount,
                  ),
                  const SizedBox(width: 10),
                  // Padding(top:3) 让昵称相对头像顶部下移 3dp（视觉平衡）
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            conv.agent.name,
                            style: const TextStyle(
                              fontSize: 17,
                              color: Color(0xFF111111),
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            conv.lastMessagePreview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Color(0xFF999999),
                              fontWeight: FontWeight.w300,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // 时间也下移 3，保持与昵称同一水平线
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      _formatTime(conv.lastMessageAt),
                      style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFFB0B0B0),
                          fontWeight: FontWeight.w300),
                    ),
                  ),
                ],
              ),
            ),
            // 分割线区域：外层填 dividerBg 让置顶间无缝；内层从 left=70 开始画线段
            Container(
              height: 0.5,
              color: dividerBg,
              child: Container(
                margin: const EdgeInsets.only(left: 70),
                color: dividerColor,
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
