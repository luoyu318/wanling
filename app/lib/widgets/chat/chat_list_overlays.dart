import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart' show chatProvider;
import 'jump_to_bottom_button.dart';
import 'unread_nav_badge.dart';

/// ChatPage 消息列表 Stack 上的条件 overlays。
///
/// 5 个互斥/条件 overlay:
/// 1. 首屏 loading(全屏转圈)
/// 2. loadMore 顶部进度条(isLoadingMore 或 300ms 延迟内)
/// 3. 空会话提示(无消息无 typing)
/// 4. 未读浮标(有未读 + 不在底部)
/// 5. 跳转底部浮标(无未读 + 不在底部)
///
/// chat_page 用 Positioned.fill 将其叠加在 ListView 之上。overlays 仅在自身命中
/// 区域(浮标/按钮)吸收点击,其余区域透传到下层 ListView,因此不使用 IgnorePointer
/// (浮标需要响应 tap)。
class ChatListOverlays extends ConsumerWidget {
  final ({String convId, String? agentId}) chatKey;
  final bool loadingHideTimerActive;
  final bool isTyping;
  final bool isAtBottom;
  final VoidCallback onScrollToBottom;
  final Future<void> Function() onJumpToBottom;

  const ChatListOverlays({
    super.key,
    required this.chatKey,
    required this.loadingHideTimerActive,
    required this.isTyping,
    required this.isAtBottom,
    required this.onScrollToBottom,
    required this.onJumpToBottom,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chatState = ref.watch(chatProvider(chatKey));
    return Stack(
      children: [
        // 首屏初始化中：loading overlay 覆盖列表
        if (chatState.isInitialLoading)
          const Positioned.fill(
            child: Center(
              child: CircularProgressIndicator(
                color: Color(0xFF07C160),
                strokeWidth: 2,
              ),
            ),
          ),

        // 加载历史 overlay：顶部细进度条。
        // LoadMoreIndicator 是列表 item，预加载时在视口外看不到；此 overlay 固定在
        // 视口顶部给用户「正在拉取」的视觉反馈。
        // 显示时机：isLoadingMore=true 期间 + 完成后延迟 300ms（loadingHideTimer 控制），
        // 让 loadMore 极快（<100ms）时用户也能看到反馈。
        if (chatState.isLoadingMore || loadingHideTimerActive)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SizedBox(
              height: 1,
              child: LinearProgressIndicator(
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation(
                  const Color(0xFF07C160),
                ),
              ),
            ),
          ),

        // 空会话提示：初始化完成且无消息无 typing 时显示
        if (!chatState.isInitialLoading &&
            chatState.displayMessages.isEmpty &&
            !isTyping)
          const Positioned.fill(
            child: Center(
              child: Text(
                '发送消息开始对话',
                style: TextStyle(
                  color: Color(0xFF999999),
                  fontSize: 14,
                ),
              ),
            ),
          ),

        // 统一未读浮标：有未读（历史未读 + 会话内新消息合并）且不在底部时显示
        if (chatState.unreadCount > 0 && !isAtBottom)
          Positioned(
            bottom: 16,
            right: 16,
            child: UnreadNavBadge(
              count: chatState.unreadCount,
              onTap: () async {
                debugPrint(
                  '[unreadBadge] TAP: scroll to bottom + jumpToBottom',
                );
                onScrollToBottom();
                await onJumpToBottom();
              },
            ),
          ),

        // 跳转底部浮标：无未读 + 不在底部时显示
        // 与未读浮标互斥（条件不会同时成立）
        // 场景：进入无未读会话 → 上滑读历史 → 提供快捷回最新的入口
        if (chatState.unreadCount == 0 && !isAtBottom)
          Positioned(
            bottom: 16,
            right: 16,
            child: JumpToBottomButton(
              onTap: () {
                debugPrint('[jumpBtn] TAP: scroll to bottom');
                onScrollToBottom();
              },
            ),
          ),
      ],
    );
  }
}
