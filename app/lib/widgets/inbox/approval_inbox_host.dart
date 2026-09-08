import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/models/inbox_entry.dart';
import 'package:app/providers/approval_inbox_provider.dart';
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/providers/auth_provider.dart'
    show apiProvider, authProvider;
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/rendering/card_renderer.dart'
    show CardContentRenderer;
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/rendering/permission_card_renderer.dart'
    show showPermissionReplySheet;
import 'package:wanling_core/rendering/question_card_renderer.dart'
    show showQuestionReplySheet;
import 'package:wanling_core/utils/snackbar.dart';

import 'inbox_source_header.dart';

/// 全局审批收件箱常驻层：挂在 MaterialApp.builder，任何页面上方监听队列。
///
/// 弹窗条件：exposing && 队列非空 && 头条会话不是当前浏览会话 && 未 suppress。
/// 抽屉内容按 kind 分叉：①②③ 复用 show*Sheet（注入来源条）；
/// ④ approvals 卡经 ContentRendererRegistry 渲染。
class ApprovalInboxHost extends ConsumerStatefulWidget {
  final Widget? child;
  const ApprovalInboxHost({super.key, this.child});

  @override
  ConsumerState<ApprovalInboxHost> createState() => _ApprovalInboxHostState();
}

class _ApprovalInboxHostState extends ConsumerState<ApprovalInboxHost> {
  /// 当前 sheet 正展示的 entry（收敛时判断是否需要关抽屉换下一条）。
  InboxEntry? _showing;
  bool _modalOpen = false;

  @override
  void initState() {
    super.initState();
    // 覆盖注入 ④ 卡决策回调：ChatNotifier 构造时注入的是裸 decideApproval
    // （chat_provider.dart:53-57），此处整体覆盖为「同款调用 + 成功后防重弹
    // 标记」，两条链路语义等价（聊天页内决策成功也会顺带打标记，无害）。
    final api = ref.read(apiProvider);
    final inbox = ref.read(approvalInboxProvider.notifier);
    CardContentRenderer.onDecide = (approvalId, actionId, reason, answers) async {
      final err = await api.decideApproval(approvalId, actionId,
          reason: reason, answers: answers);
      if (err == null) {
        final key = _showing?.kind == InboxCardKind.approvalCard
            ? _showing!.entryKey
            : null;
        if (key != null) inbox.markAwaitingConfirm(key);
      }
      return err;
    };
  }

  @override
  Widget build(BuildContext context) {
    final inbox = ref.watch(approvalInboxProvider);
    final activeConvId = ref.watch(conversationProvider.notifier).activeConvId;
    // 队列/会话变化驱动弹窗编排。
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _orchestrate(inbox, activeConvId));
    return widget.child ?? const SizedBox.shrink();
  }

  void _orchestrate(ApprovalInboxState inbox, String? activeConvId) {
    if (!mounted) return;
    final queue = inbox.queue;
    // 1) 正展示的卡已收敛（不在队列）→ 关闭当前 sheet
    if (_showing != null &&
        !queue.any((e) => e.entryKey == _showing!.entryKey)) {
      final wasAwaiting = inbox.awaitingKeys.contains(_showing!.entryKey);
      _popIfOpen();
      _showing = null;
      if (!wasAwaiting) {
        showAppSnackBar(context, '该卡片已在其他端处理', type: SnackBarType.info);
      }
    }
    // 2) 条件满足 → 弹头条
    if (_showing == null &&
        !_modalOpen &&
        inbox.exposing &&
        !inbox.suppressed &&
        queue.isNotEmpty) {
      final head = queue.first;
      // awaiting（已提交决策等收敛）的头条不重弹，防 MESSAGE_UPDATE 回流前闪现。
      if (head.convId != activeConvId &&
          !inbox.awaitingKeys.contains(head.entryKey)) {
        _showing = head;
        _showSheet(head, inbox.queue.indexOf(head) + 1, inbox.queue.length);
      }
    }
  }

  void _popIfOpen() {
    if (_modalOpen) {
      Navigator.of(context, rootNavigator: true).pop();
      _modalOpen = false;
    }
  }

  void _defer() {
    ref.read(approvalInboxProvider.notifier).dismissCurrent();
    _popIfOpen();
    _showing = null;
  }

  void _showSheet(InboxEntry e, int index, int total) {
    final conv = ref.read(convByIdProvider(e.convId));
    if (conv == null) {
      // 会话不在本地列表（冷启动直接收到他卡）：触发一次拉取补齐标题，
      // 失败仅影响来源条显示占位名，不影响决策主流程（debug log 即可）。
      // ignore: discarded_futures
      ref.read(conversationProvider.notifier).load();
    }
    // 占位名取 convId 前 8 位；不足 8 位时全量使用（防 RangeError）。
    final shortId = e.convId.length > 8 ? e.convId.substring(0, 8) : e.convId;
    final header = InboxSourceHeader(
      convId: e.convId,
      title: conv?.displayName ?? '会话 $shortId',
      avatarUrl: conv?.displayAvatarUrl,
      index: index,
      total: total,
      onDefer: _defer,
    );
    _modalOpen = true;
    switch (e.kind) {
      case InboxCardKind.ocPermission:
        _openPermissionSheet(e, header);
      case InboxCardKind.ocQuestion:
      case InboxCardKind.aggregateElement:
        // 解析器不区分聚合元素的 permission/question 形态，按载荷分派：
        // 带 questions 列表 → 问答回复抽屉；否则按权限审批抽屉处理。
        if (e.kind == InboxCardKind.ocQuestion || e.data['questions'] is List) {
          _openQuestionSheet(e, header);
        } else {
          _openPermissionSheet(e, header);
        }
      case InboxCardKind.approvalCard:
        _openApprovalCardSheet(e, header);
    }
  }

  /// sheet 关闭统一收口（决策 pop / 暂不处理 / 手势下滑）：复位弹窗守卫，
  /// 让下一次 provider 驱动的 _orchestrate 能继续编排。
  void _onSheetClosed(String entryKey) {
    _modalOpen = false;
    if (_showing?.entryKey == entryKey) _showing = null;
  }

  void _openPermissionSheet(InboxEntry e, Widget header) {
    unawaited(showPermissionReplySheet(
      context,
      convId: e.convId,
      ocRequestId: e.data['oc_request_id'] as String? ?? '',
      action: e.data['action'] as String? ?? '',
      resources: (e.data['resources'] as List?)?.cast<String>() ?? const [],
      metadata: e.data['metadata'] is Map
          ? Map<String, dynamic>.from(e.data['metadata'] as Map)
          : const <String, dynamic>{},
      save: (e.data['save'] as List?)?.cast<String>() ?? const [],
      header: header,
      onSettled: () {
        // 决策成功后 sheet 自行 pop；先复位弹窗守卫，防收敛 UPDATE 在
        // pop 动画期间触发 _orchestrate 对底层路由的二次 pop。
        _modalOpen = false;
        ref.read(approvalInboxProvider.notifier).markAwaitingConfirm(e.entryKey);
      },
    ).whenComplete(() => _onSheetClosed(e.entryKey)));
  }

  void _openQuestionSheet(InboxEntry e, Widget header) {
    final questions = (e.data['questions'] as List?)
            ?.map((x) => Map<String, dynamic>.from(x as Map))
            .toList() ??
        const <Map<String, dynamic>>[];
    unawaited(showQuestionReplySheet(
      context,
      convId: e.convId,
      ocRequestId: e.data['oc_request_id'] as String? ?? '',
      questions: questions,
      header: header,
      onSettled: () {
        // 决策成功后 sheet 自行 pop；先复位弹窗守卫，防收敛 UPDATE 在
        // pop 动画期间触发 _orchestrate 对底层路由的二次 pop。
        _modalOpen = false;
        ref.read(approvalInboxProvider.notifier).markAwaitingConfirm(e.entryKey);
      },
    ).whenComplete(() => _onSheetClosed(e.entryKey)));
  }

  void _openApprovalCardSheet(InboxEntry e, Widget header) {
    final api = ref.read(apiProvider);
    final auth = ref.read(authProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final rc = MessageRenderContext(
      isMe: false,
      baseUrl: api.baseUrl,
      token: auth.token ?? '',
      isDark: isDark,
      convId: e.convId,
      messageId: e.msgId,
    );
    unawaited(showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(top: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFFDDDDDD),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              header,
              const Divider(height: 1, color: Color(0xFFEEEEEE)),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ContentRendererRegistry.render(
                    MsgType.card,
                    {'msg_type': MsgType.card.value, 'data': e.data},
                    ctx,
                    rc,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ).whenComplete(() => _onSheetClosed(e.entryKey)));
  }
}
