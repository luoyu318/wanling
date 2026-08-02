import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart' show chatProvider;
import 'message_input_bar.dart';
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

    // agent_session 定制:纯白背景 + 模式竖线 + flatInput
    if (chatState.convType == 'agent_session') {
      final effectiveMode = chatState.modeOverride ?? chatState.sessionMeta?.mode ?? '';
      final modeColor = effectiveMode.toLowerCase() == 'plan'
          ? const Color(0xFFF4A742)
          : const Color(0xFF597BFF);

      return MessageInputBar(
        key: inputBarKey,
        onSend: inputController.send,
        onPickFile: inputController.pickFile,
        onTakePhoto: inputController.takePhoto,
        onPickAlbum: inputController.pickAlbum,
        topOverlay: topOverlay,
        backgroundColor: Colors.white,
        flatInput: true,
        accentColor: modeColor,
        showModeBar: false,
        onSendSlash: onSendSlash,
      );
    }

    // dm/群聊:完全不变
    return MessageInputBar(
      onSend: inputController.send,
      onPickFile: inputController.pickFile,
      onTakePhoto: inputController.takePhoto,
      onPickAlbum: inputController.pickAlbum,
      topOverlay: topOverlay,
    );
  }
}
