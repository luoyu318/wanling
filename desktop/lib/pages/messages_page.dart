import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/conversation_provider.dart';
import '../providers/detail_panel_provider.dart';
import '../providers/no_conversation_hint_provider.dart';
import '../providers/selected_conv_provider.dart';
import '../widgets/conversation_list.dart';
import '../widgets/detail_panel.dart';
import 'chat/chat_view.dart';

/// 详情侧栏宽度(宽窗内联固定 400px,窄窗浮层钳到窗口宽)。
const double kDetailPanelWidth = 400;

/// 宽窗/窄窗分界:<1000 走 Stack 覆盖浮层,≥1000 走 Row 内联挤压。
const double kDetailPanelWideBreakpoint = 1000;

/// 消息页:三栏布局 —— 左会话列表(240px)+ 中聊天区 + 右详情侧栏。
/// 选中态由 selectedConvProvider 驱动;agentId 从 conversationProvider 查
/// (agent_session 不在列表内,查不到时 null 兜底)。
/// ChatView 按 convId 打 key:切换会话强制重建,列表重新走贴底定位。
///
/// 详情侧栏(Task 7):
/// - 宽窗(≥1000):AnimatedContainer 内联在 Row 尾部,开 400px / 关 0,
///   聊天区随之后缩;
/// - 窄窗(<1000):Stack 右侧覆盖浮层(带投影),不挤压聊天区。
/// 面板内容仅在展开时挂载(收起即卸载,sessionDiffProvider 随之释放)。
///
/// 无会话提示(noConversationHintProvider):万灵页点无会话 agent 卡片时写入,
/// 在本页空态展示;切到会话(ref.listen selectedConvProvider)或经 NavRail 离开
/// 本页即清除,保证提示不残留。
class MessagesPage extends ConsumerWidget {
  const MessagesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final panelOpen = ref.watch(detailPanelOpenProvider);
    final selectedId = ref.watch(selectedConvProvider);
    // 切到具体会话即清除万灵页的无会话提示(空态被会话取代)。
    ref.listen(selectedConvProvider, (prev, next) {
      if (next != null) {
        ref.read(noConversationHintProvider.notifier).state = null;
      }
    });
    final hint = ref.watch(noConversationHintProvider);
    final agentId = selectedId == null
        ? null
        : ref
            .watch(conversationProvider)
            .where((c) => c.id == selectedId)
            .firstOrNull
            ?.agent
            ?.id;

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >= kDetailPanelWideBreakpoint;
          final panelWidth = wide
              ? kDetailPanelWidth
              : constraints.maxWidth.clamp(0, kDetailPanelWidth).toDouble();

          final chatArea = Container(
            key: ValueKey('chat_area_$selectedId'),
            color: scheme.surface,
            child: selectedId == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 48,
                          color: scheme.onSurface.withValues(alpha: 0.2),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          '选择一个会话开始聊天',
                          style: TextStyle(
                            fontSize: 14,
                            color: scheme.onSurface.withValues(alpha: 0.4),
                          ),
                        ),
                        if (hint != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            hint,
                            key: const ValueKey('no_conv_hint'),
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  )
                : ChatView(
                    key: ValueKey('chat_view_$selectedId'),
                    convId: selectedId,
                    agentId: agentId,
                  ),
          );

          // 详情侧栏:宽度动画(开=panelWidth,关=0),内容仅在展开时挂载
          final panel = AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            width: panelOpen ? panelWidth : 0,
            decoration: BoxDecoration(
              color: scheme.surface,
              border: Border(
                left: BorderSide(color: scheme.outlineVariant),
              ),
              boxShadow: wide || !panelOpen
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.25),
                        blurRadius: 12,
                      ),
                    ],
            ),
            child: ClipRect(
              child: panelOpen && selectedId != null
                  ? DetailPanel(convId: selectedId, agentId: agentId)
                  : const SizedBox.expand(),
            ),
          );

          if (wide) {
            return Row(
              children: [
                const SizedBox(width: 240, child: ConversationList()),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: chatArea),
                panel,
              ],
            );
          }
          return Stack(
            children: [
              Row(
                children: [
                  const SizedBox(width: 240, child: ConversationList()),
                  const VerticalDivider(width: 1, thickness: 1),
                  Expanded(child: chatArea),
                ],
              ),
              Positioned(top: 0, bottom: 0, right: 0, child: panel),
            ],
          );
        },
      ),
    );
  }
}
