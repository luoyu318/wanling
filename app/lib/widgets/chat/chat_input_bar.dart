import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/agent_mode.dart';
import 'package:wanling_core/providers/agent_modes_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show chatProvider;
import 'package:app/providers/pending_attachment_provider.dart';
import 'message_input_bar.dart';
import 'pending_attachment_bar.dart';
import 'quote_preview_bar.dart' show QuotePreviewBar;
import 'input_controller.dart' show InputController;

/// ChatPage 的输入栏。自己 watch chatProvider 获取 pendingQuote/convType/sessionMeta。
///
/// convType 分流:
/// - agent_session:纯白背景 + 模式竖线 + flatInput
/// - 其他(dm/群聊):标准 MessageInputBar
class ChatInputBar extends ConsumerWidget {
  final InputController inputController;
  final ({String convId, String? agentId}) chatKey;
  /// slash 命令发送回调(传命令名 + args)。仅 agent_session 用。
  final void Function(String name, String args)? onSendSlash;
  /// agent_session 分支 MessageInputBar 的 GlobalKey。
  /// Task 8 的 chat_page 通过它做 dynamic dispatch 访问
  /// _MessageInputBarState.setSlash(选了命令胶囊后回填到输入栏)。
  /// dm/群聊分支不传(无 slash 能力)。
  final Key? inputBarKey;

  const ChatInputBar({
    super.key,
    required this.inputController,
    required this.chatKey,
    this.onSendSlash,
    this.inputBarKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingQuote = ref.watch(
      chatProvider(chatKey).select((s) => s.pendingQuote),
    );
    final chatState = ref.watch(chatProvider(chatKey));

    final topOverlay = pendingQuote != null
        ? QuotePreviewBar(
            quote: pendingQuote,
            onCancel: () =>
                ref.read(chatProvider(chatKey).notifier).clearPendingQuote(),
          )
        : null;

    final pendingAttachment = ref.watch(
      pendingAttachmentProvider(chatKey),
    );
    final attachmentBar = pendingAttachment != null
        ? PendingAttachmentBar(
            attachment: pendingAttachment,
            onRemove: () => ref
                .read(pendingAttachmentProvider(chatKey).notifier)
                .state = null,
          )
        : null;
    // topOverlay 单槽组合:缩略图条在上、引用预览在下(可并存)
    Widget? overlay;
    if (attachmentBar != null || topOverlay != null) {
      overlay = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (attachmentBar != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: attachmentBar,
            ),
          if (topOverlay != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: topOverlay,
            ),
        ],
      );
    }

    // agent_session 定制:纯白背景 + 模式竖线 + flatInput
    if (chatState.convType == 'agent_session') {
      final effectiveMode = chatState.modeOverride ?? chatState.sessionMeta?.mode ?? '';
      // 模式色:清单驱动(plugin 上报 style 档位)→ 未命中回退 'plan'
      // 特例(老插件兼容期),再兜底品牌蓝。
      final modeColor = _modeColor(ref, chatKey.agentId, effectiveMode);

      return MessageInputBar(
        key: inputBarKey,
        onSend: inputController.send,
        onPickFile: inputController.pickFile,
        onTakePhoto: inputController.takePhoto,
        onPickAlbum: inputController.pickAlbum,
        topOverlay: overlay,
        backgroundColor: Colors.white,
        flatInput: true,
        accentColor: modeColor,
        showModeBar: false,
        onSendSlash: onSendSlash,
        hasPendingAttachment: pendingAttachment != null,
      );
    }

    // dm/群聊:完全不变
    return MessageInputBar(
      onSend: inputController.send,
      onPickFile: inputController.pickFile,
      onTakePhoto: inputController.takePhoto,
      onPickAlbum: inputController.pickAlbum,
      topOverlay: overlay,
      hasPendingAttachment: pendingAttachment != null,
    );
  }

  /// 模式色解析:上报清单 style 档位 → 语义色;清单缺失/未命中回退
  /// 'plan' 特例(plan=橙),再兜底品牌蓝。档位色集中在 core 定义,
  /// 端侧不维护各平台枚举(proposal-agent-modes.md §3.4)。
  Color _modeColor(WidgetRef ref, String? agentId, String mode) {
    final catalog = agentId == null
        ? const <AgentMode>[]
        : ref.watch(agentModesProvider(agentId)).valueOrNull ?? const [];
    final style = findModeById(catalog, mode)?.style;
    if (style != null) {
      return switch (style.visualStyle) {
        AgentModeVisualStyle.plan => const Color(0xFFF4A742),
        AgentModeVisualStyle.warn => const Color(0xFFE5484D),
        AgentModeVisualStyle.brand => const Color(0xFF597BFF),
      };
    }
    // 回退:老插件未上报清单,保留 plan 特例。
    return mode.toLowerCase() == 'plan'
        ? const Color(0xFFF4A742)
        : const Color(0xFF597BFF);
  }
}
