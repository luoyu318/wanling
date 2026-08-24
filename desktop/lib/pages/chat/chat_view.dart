import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_core/widgets/feedback/app_snackbar.dart';
import 'package:wanling_desktop/providers/detail_panel_provider.dart';
import 'package:wanling_desktop/widgets/chat/desktop_input_bar.dart';
import 'package:wanling_desktop/widgets/chat/env_meta_strip.dart';
import 'package:wanling_core/providers/agent_modes_provider.dart';
import 'package:wanling_core/providers/agent_status_provider.dart' show agentStatusProvider;
import 'package:wanling_desktop/widgets/chat/model_picker_sheet.dart';
import 'package:wanling_desktop/widgets/chat/mode_picker_sheet.dart';
import 'package:wanling_desktop/widgets/chat/session_meta_strip.dart';
import 'package:wanling_desktop/widgets/chat/stop_bar.dart';
import 'chat_app_bar.dart';
import 'chat_message_list.dart';

/// 桌面聊天区:core chatProvider((convId, agentId)) 驱动,
/// ChatAppBar(会话名 + gitBranch 徽标 + 详情开关)+ SessionMetaStrip
/// (agent_session 的 mode/model 切换条,移植自 app 壳)+ ChatMessageList +
/// DesktopInputBar(Task 6:工具栏上置 + slash/提及面板 + 文件图片)。
class ChatView extends ConsumerWidget {
  final String convId;
  final String? agentId;

  const ChatView({super.key, required this.convId, this.agentId});

  /// 模型选择:拉 agent 模型清单 → 弹 ModelPickerDialog → selectModel。
  /// 空清单/失败走 snackbar 反馈(对齐 app 壳 _showModelPicker 策略)。
  Future<void> _showModelPicker(
    BuildContext context,
    WidgetRef ref,
  ) async {
    if (agentId == null) return;
    try {
      final models = await ref.read(apiProvider).getAgentModels(agentId!);
      if (!context.mounted) return;
      if (models.isEmpty) {
        showAppSnackBar(context, '暂无可选模型');
        return;
      }
      final currentState = ref.read(chatProvider((convId: convId, agentId: agentId)));
      final selected = await ModelPickerDialog.show(
        context: context,
        models: models,
        currentOverride: currentState.modelOverride,
        currentSessionMeta: currentState.sessionMeta,
      );
      if (selected != null) {
        ref
            .read(chatProvider((convId: convId, agentId: agentId)).notifier)
            .selectModel(selected);
      }
    } catch (_) {
      if (!context.mounted) return;
      showAppSnackBar(context, '模型列表加载失败');
    }
  }

  /// 模式选择:清单驱动(plugin 上报 AGENT_MODES)。
  /// 空清单(老插件未上报)回退 build↔plan 二值切换(OC 兼容期)。
  Future<void> _showModePicker(BuildContext context, WidgetRef ref) async {
    final chatNotifier = ref
        .read(chatProvider((convId: convId, agentId: agentId)).notifier);
    if (agentId != null) {
      try {
        final modes =
            await ref.read(agentModesProvider(agentId!).future);
        if (modes.isNotEmpty && context.mounted) {
          final chatState =
              ref.read(chatProvider((convId: convId, agentId: agentId)));
          final selected = await ModePickerDialog.show(
            context: context,
            modes: modes,
            currentMode: chatState.modeOverride ?? chatState.sessionMeta?.mode,
          );
          if (selected != null) chatNotifier.selectMode(selected);
          return;
        }
      } catch (_) {/* 拉取失败走回退 */}
    }
    chatNotifier.toggleMode();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chat = ref.watch(chatProvider((convId: convId, agentId: agentId)));
    final currentUserId = ref.watch(
      authProvider.select((s) => s.user?.id ?? ''),
    );
    final baseUrl = ref.watch(settingsProvider);
    final token = ref.watch(authProvider.select((s) => s.token ?? ''));
    final scheme = Theme.of(context).colorScheme;

    return Column(
      children: [
        ChatAppBar(
          title: chat.convTitle ?? '会话',
          gitBranch: chat.sessionMeta?.gitBranch,
          agentId: agentId,
        ),
        Expanded(
          child: chat.isInitialLoading
              ? Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: scheme.primary.withValues(alpha: 0.6),
                    ),
                  ),
                )
              : ChatMessageList(
                  convId: convId,
                  agentId: agentId,
                  currentUserId: currentUserId,
                  baseUrl: baseUrl,
                  token: token,
                ),
        ),
        // agent_session 输入面板区(对齐 app 壳,两条 meta 条合并为一行:
        // SessionMetaStrip(mode/model)居左 + EnvMetaStrip(cwd/branch/token)
        // 紧随其后,空间不足各自横向滚动;非 agent_session 不渲染):
        //   分割线 + 单行双 strip + 分割线 + DesktopInputBar。
        if (chat.convType == 'agent_session' && chat.sessionMeta != null) ...[
          Container(height: 1, color: Theme.of(context).dividerTheme.color ?? const Color(0xFFE4E4E4)),
          Container(
            key: const ValueKey('session_meta_strip'),
            width: double.infinity,
            // 透明透出外层聊天卡片底色(Task 7 CardContainer)
            color: Colors.transparent,
            padding: const EdgeInsets.fromLTRB(16, 3, 16, 3),
            child: Row(
              children: [
                Flexible(
                  child: SessionMetaStrip(
                    meta: chat.sessionMeta!,
                    modeOverride: chat.modeOverride,
                    // 模式清单(plugin 上报):label/style 档位渲染数据源。
                    modes: agentId == null
                        ? const []
                        : ref
                                .watch(agentModesProvider(agentId!))
                                .valueOrNull ??
                            const [],
                    onModeTap: () => _showModePicker(context, ref),
                    modelOverride: chat.modelOverride,
                    onModelTap: () => _showModelPicker(context, ref),
                  ),
                ),
                const SizedBox(width: 14),
                Flexible(
                  child: EnvMetaStrip(
                    key: const ValueKey('env_meta_strip'),
                    cwd: chat.directory,
                    gitBranch: chat.sessionMeta?.gitBranch,
                    tokensTotal: chat.sessionMeta?.tokensTotal,
                    contextUsed: chat.sessionMeta?.contextUsed,
                    contextLimit: chat.sessionMeta?.contextLimit,
                    // gitBranch 段点击:打开详情面板(Changes tab 即 session diff)。
                    onTapGitBranch: () => ref
                        .read(detailPanelOpenProvider.notifier)
                        .state = true,
                  ),
                ),
                // 常驻停止按钮(对齐 app 端 StopBar):双击确认防误触,点击即
                // POST /api/conversations/:id/abort(server dispatch
                // GENERATION_ABORT → plugin 中止生成)。
                StopBar(
                  isGenerating:
                      ref.watch(agentStatusProvider.select((s) => s[convId])) != null,
                  onTap: () => ref.read(apiProvider).abortGeneration(convId),
                ),
              ],
            ),
          ),
          // 此处不画分割线:DesktopInputBar 自带顶边框
          // (desktop_input_bar.dart Border.top),再画会重叠成双线。
        ],
        DesktopInputBar(convId: convId, agentId: agentId),
      ],
    );
  }
}
