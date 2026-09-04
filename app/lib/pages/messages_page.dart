import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/nav_order_provider.dart';
import '../router_helpers.dart';
import 'package:wanling_core/utils/emoji_span.dart';
import 'package:wanling_core/utils/snackbar.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../widgets/agent_badge.dart';
import '../widgets/avatar.dart';
import '../widgets/conv_action_menu.dart';
import '../widgets/conv_slidable.dart';
import '../widgets/draft_preview.dart';

/// 消息列表页（IM 风格）。
///
/// 设计要点：
/// - ConsumerStatefulWidget：用 initState 在首次进入时触发 load（拉取最新列表）。
/// - 下拉刷新由 _MsgNavPage 的 MiniProgramPullScope 统一注入(轻拉=刷新,
///   深拉=小程序面板),空态 ListView 同样受其手势覆盖。
/// - 会话栏:padding horizontal/vertical 12,无分割线(mockup 对齐)。
/// - 置顶会话:浅灰背景 #EDEDED。
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
    final currentUserId = ref.watch(authProvider).user?.id ?? '';
    // 左滑「固定到底栏」按钮文案由底栏固定序列驱动,pin/unpin 后即时刷新。
    final navIds = ref.watch(navOrderProvider);

    // AppBar 移到 HomePage 共享管理，这里直接返回 body 内容。
    // 背景白底衬会话 tile。
    // 下拉刷新由 _MsgNavPage 的 MiniProgramPullScope 统一注入(轻拉=刷新,
    // 深拉=小程序面板),空态 ListView 同样受其手势覆盖。
    return ColoredBox(
      color: Colors.white,
      child: list.isEmpty
          ? _EmptyState(
              onRetry: () => ref.read(conversationProvider.notifier).load(),
            )
          : SlidableAutoCloseBehavior(
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: list.length,
                itemBuilder: (_, i) {
                  final c = list[i];
                  // multi_session 聚合行固定的是 agent 槽(与二级页图钉一致),
                  // 其余行固定会话槽('conv:<convId>')。
                  final navId = (c.agent?.isMultiSession ?? false)
                      ? c.agent!.id
                      : navConvRef(c.id);
                  final navPinned = navIds.contains(navId);
                  return ConvSlidable(
                    slideKey: ValueKey('slide_conv_${c.id}'),
                    actions: [
                      SlideActionSpec(
                        icon: navPinned ? Icons.dock_outlined : Icons.dock,
                        label: navPinned ? '从底栏移除' : '固定到底栏',
                        color: const Color(0xFF3C7CF7),
                        onTap: () async {
                          try {
                            final n = ref.read(navOrderProvider.notifier);
                            if (navPinned) {
                              n.unpin(navId);
                            } else {
                              n.pin(navId);
                            }
                          } catch (_) {
                            if (context.mounted) {
                              showAppSnackBar(
                                context,
                                '操作失败,请重试',
                                type: SnackBarType.error,
                              );
                            }
                          }
                        },
                      ),
                      SlideActionSpec(
                        icon: Icons.vertical_align_top,
                        label: c.isPinned ? '取消置顶' : '置顶',
                        color: const Color(0xFFFFA426),
                        onTap: () async {
                          try {
                            final n = ref.read(conversationProvider.notifier);
                            if (c.isPinned) {
                              await n.unpin(c.id);
                            } else {
                              await n.pin(c.id);
                            }
                          } catch (_) {
                            if (context.mounted) {
                              showAppSnackBar(
                                context,
                                '操作失败,请重试',
                                type: SnackBarType.error,
                              );
                            }
                          }
                        },
                      ),
                      SlideActionSpec(
                        icon: Icons.delete_outline,
                        label: '删除会话',
                        color: const Color(0xFFFA5151),
                        onTap: () => confirmHideConversation(
                          context,
                          () => ref
                              .read(conversationProvider.notifier)
                              .hide(c.id),
                        ),
                      ),
                    ],
                    child: _ConvTile(
                      conv: c,
                      key: ValueKey('conv_${c.id}'),
                      currentUserId: currentUserId,
                      // 一级列表按 agent.type 路由(spec §7.1):
                      //   多 session 开发型 agent(opencode 类)→ 二级 session 群列表页
                      //   对话型 agent / user-user → 单聊页
                      // 老服务器 ag.type 缺字段时 fallback '',走单聊分支(向后兼容)。
                      onTap: () {
                        // server 按 type 注册表注入 multi_session;null(老
                        // server)fallback type=='opencode'(AgentSummary 内)。
                        if (c.agent?.isMultiSession ?? false) {
                          context.push(sessionsRoute(c.agent!.id));
                        } else {
                          context.push(chatRoute(c.id, c.agent?.id));
                        }
                      },
                      onLongPressStart: (details) => showConvActionMenu(
                        context,
                        details.globalPosition,
                        isPinned: c.isPinned,
                        isNavPinned: navPinned,
                        onPinToggle: () => c.isPinned
                            ? ref
                                  .read(conversationProvider.notifier)
                                  .unpin(c.id)
                            : ref
                                  .read(conversationProvider.notifier)
                                  .pin(c.id),
                        // NavOrderNotifier.pin/unpin 是同步 void,async 包装
                        // 适配 onNavPinToggle 的 Future<void> Function() 签名。
                        onNavPinToggle: () async => navPinned
                            ? ref.read(navOrderProvider.notifier).unpin(navId)
                            : ref.read(navOrderProvider.notifier).pin(navId),
                        onHide: () => ref
                            .read(conversationProvider.notifier)
                            .hide(c.id),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
  }
}

/// 空状态。ListView 包裹使内容可滚动,空列表同样受 _MsgNavPage 层
/// MiniProgramPullScope 手势覆盖(下拉刷新可用)。
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
/// 按下（点击/长按）时背景变更反馈色，松开恢复；长按触发 HapticFeedback。
class _ConvTile extends StatefulWidget {
  final Conversation conv;
  final String currentUserId; // 用于 lastMessagePreview 切「你/对方撤回」
  final VoidCallback onTap;
  final Future<void> Function(LongPressStartDetails details) onLongPressStart;
  const _ConvTile({
    super.key,
    required this.conv,
    required this.currentUserId,
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
    // tile 背景：按下时切到深一档（普通 #EDEDED / 置顶 #D6D6D6），松开恢复
    final tileBg = _isPressed
        ? (conv.isPinned ? const Color(0xFFD6D6D6) : const Color(0xFFEDEDED))
        : (conv.isPinned ? const Color(0xFFEDEDED) : Colors.white);

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
        if (_downPos != null && (e.position - _downPos!).distance > 8) {
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
          unawaited(HapticFeedback.selectionClick());
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
          onTap: () {
            // 左滑展开态点击内容区:仅收起,不进会话(slidable 无此默认行为,显式守卫)。
            final slidable = Slidable.of(context);
            if (slidable != null &&
                slidable.actionPaneType.value != ActionPaneType.none) {
              unawaited(slidable.close());
              return;
            }
            widget.onTap();
          },
          // tap 反馈归位由 Listener.onPointerUp 处理（更早、更可靠）
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          child: Container(
            color: tileBg,
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            // crossAxisAlignment.start 让时间 Text 顶部和昵称 Text 顶部对齐
            // （Row 默认 center 会让时间垂直居中到头像中线）。
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Avatar(
                  name: conv.displayName,
                  url: conv.displayAvatarUrl,
                  size: 48,
                  radius: 13,
                  tinted: true,
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
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                conv.displayName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 15,
                                  color: Color(0xFF111111),
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                            // dm_user_agent 会话标 agent 类型标签(按 type 区分颜色)
                            if (conv.isUserAgentDM) ...[
                              const SizedBox(width: 4),
                              AgentBadge(type: conv.agent?.type ?? ''),
                            ],
                          ],
                        ),
                        const SizedBox(height: 2),
                        if (conv.isUserAgentDM &&
                            (conv.agent?.isMultiSession ?? false))
                          Text(
                            conv.pendingCount > 0
                                ? '待处理 ${conv.pendingCount} 项'
                                : (conv.sessionCount > 0
                                      ? '${conv.sessionCount} 个会话'
                                      : '暂无会话'),
                            style: TextStyle(
                              fontSize: 12,
                              color: conv.pendingCount > 0
                                  ? const Color(0xFFE53935)
                                  : const Color(0xFF999999),
                              fontWeight: FontWeight.w400,
                            ),
                          )
                        else
                          DraftAwarePreview(
                            convId: conv.id,
                            fallback: buildEmojiColoredText(
                              conv.lastMessagePreview(
                                currentUserId: widget.currentUserId,
                                isGroup: conv.isGroup,
                                senderDisplayName: conv.lastMessageSenderName,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF999999),
                                fontWeight: FontWeight.w400,
                              ),
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
                      color: Color(0xFF999999),
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
