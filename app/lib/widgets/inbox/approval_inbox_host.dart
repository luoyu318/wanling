import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:app/models/inbox_entry.dart';
import 'package:app/providers/approval_inbox_provider.dart';
import 'package:app/router.dart' show navigatorKey;
import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/providers/auth_provider.dart'
    show apiProvider, authProvider;
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/inbox_popup_pref_provider.dart';
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

  /// 弹窗用的根 Navigator。Host 挂在 MaterialApp.builder 层，其 context
  /// 的祖先链不含 Navigator（showModalBottomSheet 向上查找必抛
  /// "does not include a Navigator"），必须显式持有根 key。
  /// 默认取全局 router key；测试注入私有 key。
  final GlobalKey<NavigatorState>? navigatorKey;
  const ApprovalInboxHost({super.key, this.child, this.navigatorKey});

  @override
  ConsumerState<ApprovalInboxHost> createState() => _ApprovalInboxHostState();
}

class _ApprovalInboxHostState extends ConsumerState<ApprovalInboxHost> {
  /// 当前 sheet 正展示的 entry（收敛时判断是否需要关抽屉换下一条）。
  InboxEntry? _showing;
  bool _modalOpen = false;

  /// 不在列表 state 的会话（agent_session 被 ListForUser 过滤 / 冷启动）
  /// 的标题回填：convId → 异步单查 getConversation 后更新的 notifier。
  /// 按 convId 缓存复用（同一会话再次弹卡直接有值，不再发请求）。
  final Map<String, ValueNotifier<String>> _titleNotifiers = {};

  ValueNotifier<String> _titleNotifierFor(String convId, String initial) =>
      _titleNotifiers.putIfAbsent(convId, () => ValueNotifier<String>(initial));

  /// 单查回填会话标题；失败保留占位（来源条显示不受影响）。
  /// notifier 由 [_titleNotifiers] 永久缓存，随 Host 存活，无 dispose 竞态。
  void _fetchTitleIfMissing(String convId, ValueNotifier<String> notifier) {
    final api = ref.read(apiProvider);
    // ignore: discarded_futures
    api.getConversation(convId).then((conv) {
      notifier.value = conv.displayName;
    }).catchError((Object _) {});
  }

  /// 当前 sheet 是否已收敛（决策/拒绝成功，或编排层主动关闭）。
  /// 被动关闭（返回键/手势下滑/点遮罩）不置位，_onSheetClosed 据此补发
  /// dismissCurrent——与 spec §6「返回键等同暂不处理」对齐，防 exposing
  /// 泄漏导致旧卡在新状态变化时未经防抖立即重弹。
  bool _sheetSettled = false;

  @override
  void initState() {
    super.initState();
    // 注入 ④ 卡决策回调（所有权唯一化）：ChatNotifier 构造时经 ??= 兜底
    // 安装裸 decideApproval（chat_provider.dart:56），仅在无人安装时生效、
    // 不与 Host 抢；此处注册「同款调用 + 成功后防重弹标记」增强版，两条
    // 链路语义等价（聊天页内决策成功也会顺带打标记，无害）。
    final api = ref.read(apiProvider);
    final inbox = ref.read(approvalInboxProvider.notifier);
    CardContentRenderer.onDecide = (approvalId, actionId, reason, answers) async {
      final err = await api.decideApproval(approvalId, actionId,
          reason: reason, answers: answers);
      if (err == null) {
        final key = _showing?.kind == InboxCardKind.approvalCard
            ? _showing!.entryKey
            : null;
        if (key != null) {
          inbox.markAwaitingConfirm(key);
          // ④ 卡决策成功视为已收敛：后续被动关 sheet 不再补 dismiss。
          _sheetSettled = true;
        }
      }
      return err;
    };
  }

  /// 根 Navigator（弹窗/pop 统一走它；见 [ApprovalInboxHost.navigatorKey]）。
  GlobalKey<NavigatorState> get _navKey => widget.navigatorKey ?? navigatorKey;

  @override
  Widget build(BuildContext context) {
    final inbox = ref.watch(approvalInboxProvider);
    // watch state（而非 notifier 对象）：进出聊天页时 setActiveConv 广播
    // state，触发本层 rebuild → postFrame 重新编排，兑现「退出会话后恢复可弹」。
    ref.watch(conversationProvider);
    final activeConvId = ref.read(conversationProvider.notifier).activeConvId;
    // 自动弹出开关:watch 建立订阅,重开开关时 rebuild → postFrame 编排,
    // 积压卡自然弹出;关闭时只拦弹窗,队列照常收集。
    final autoPopup = ref.watch(inboxPopupPrefProvider);
    // 队列/会话变化驱动弹窗编排。
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _orchestrate(inbox, activeConvId, autoPopup));
    return widget.child ?? const SizedBox.shrink();
  }

  void _orchestrate(
      ApprovalInboxState inbox, String? activeConvId, bool autoPopup) {
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
    // 2) 条件满足 → 弹头条(开关关闭时不自动弹,卡保留在队列)
    if (autoPopup &&
        _showing == null &&
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
      // 编排层主动关闭（收敛换卡/暂不处理）视为已收敛，_onSheetClosed 不补 dismiss。
      _sheetSettled = true;
      _navKey.currentState?.pop();
      _modalOpen = false;
    }
  }

  void _defer() {
    ref.read(approvalInboxProvider.notifier).dismissCurrent();
    _popIfOpen();
    _showing = null;
  }

  void _showSheet(InboxEntry e, int index, int total) {
    // builder 层 context 不含 Navigator，弹窗必须用根 Navigator 的 context。
    final navCtx = _navKey.currentContext;
    if (navCtx == null) {
      // 根 Navigator 未挂载（理论不可达，app 启动完成才有消息流）：fail fast
      // 复位守卫让下次编排重试，卡保留在队列。
      assert(false, 'ApprovalInboxHost: 根 Navigator 未挂载，无法弹出收件箱');
      _showing = null;
      _modalOpen = false;
      _sheetSettled = false;
      return;
    }
    final conv = ref.read(convByIdProvider(e.convId));
    // 占位名取 convId 前 8 位；不足 8 位时全量使用（防 RangeError）。
    final shortId = e.convId.length > 8 ? e.convId.substring(0, 8) : e.convId;
    final placeholder = '会话 $shortId';
    // 会话不在列表 state（agent_session 被过滤 / 冷启动未拉全）：
    // 标题走回填 notifier，getConversation 单查返回后来源条实时刷新。
    final needsFetch = conv == null;
    final title = conv?.displayName ?? placeholder;
    final titleNotifier = needsFetch ? _titleNotifierFor(e.convId, placeholder) : null;
    if (needsFetch) {
      _fetchTitleIfMissing(e.convId, titleNotifier!);
    }
    final header = InboxSourceHeader(
      convId: e.convId,
      title: title,
      titleListenable: titleNotifier,
      avatarUrl: conv?.displayAvatarUrl,
      index: index,
      total: total,
      onDefer: _defer,
    );
    _modalOpen = true;
    // 新 sheet 打开前重置收敛标记：本次展示周期的被动关闭才走补 dismiss。
    _sheetSettled = false;
    switch (e.kind) {
      case InboxCardKind.ocPermission:
        _openPermissionSheet(navCtx, e, header);
      case InboxCardKind.ocQuestion:
      case InboxCardKind.aggregateElement:
        // 解析器不区分聚合元素的 permission/question 形态，按载荷分派：
        // 带 questions 列表 → 问答回复抽屉；否则按权限审批抽屉处理。
        if (e.kind == InboxCardKind.ocQuestion || e.data['questions'] is List) {
          _openQuestionSheet(navCtx, e, header);
        } else {
          _openPermissionSheet(navCtx, e, header);
        }
      case InboxCardKind.approvalCard:
        _openApprovalCardSheet(navCtx, e, header);
    }
  }

  /// sheet 关闭统一收口（决策 pop / 暂不处理 / 手势下滑）：复位弹窗守卫，
  /// 让下一次 provider 驱动的 _orchestrate 能继续编排。
  void _onSheetClosed(String entryKey) {
    // 归属判定：仅处理当前展示周期的关闭。收敛换卡在同一 post-frame 内
    // pop 旧 sheet 并弹新卡（_sheetSettled 被新周期重置 false），旧 sheet
    // 路由 dispose 的迟到 close 若不忽略，会对新头条误发 dismissCurrent
    // （suppressed=true/exposing=false，队列剩余卡静默停摆），还会复位
    // 新周期的 _modalOpen 守卫。非本周期关闭一律忽略（各发起方 pop 时
    // 已自行复位守卫）。
    if (_showing?.entryKey != entryKey) return;
    // 被动关闭（返回键/下滑/遮罩）≠ 决策收敛：补发 dismissCurrent，
    // 语义等同「暂不处理」（spec §6），防 exposing 泄漏导致旧卡未经
    // 新卡驱动的防抖就立即重弹。决策/拒绝成功路径已置位，跳过。
    if (!_sheetSettled) {
      ref.read(approvalInboxProvider.notifier).dismissCurrent();
    }
    _sheetSettled = false;
    _modalOpen = false;
    _showing = null;
  }

  void _openPermissionSheet(
      BuildContext navCtx, InboxEntry e, Widget header) {
    unawaited(showPermissionReplySheet(
      navCtx,
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
        _sheetSettled = true;
        _modalOpen = false;
        ref.read(approvalInboxProvider.notifier).markAwaitingConfirm(e.entryKey);
      },
    ).whenComplete(() => _onSheetClosed(e.entryKey)));
  }

  void _openQuestionSheet(
      BuildContext navCtx, InboxEntry e, Widget header) {
    final questions = (e.data['questions'] as List?)
            ?.map((x) => Map<String, dynamic>.from(x as Map))
            .toList() ??
        const <Map<String, dynamic>>[];
    unawaited(showQuestionReplySheet(
      navCtx,
      convId: e.convId,
      ocRequestId: e.data['oc_request_id'] as String? ?? '',
      questions: questions,
      header: header,
      onSettled: () {
        // 决策/拒绝成功后 sheet 自行 pop；先复位弹窗守卫，防收敛 UPDATE 在
        // pop 动画期间触发 _orchestrate 对底层路由的二次 pop。
        _sheetSettled = true;
        _modalOpen = false;
        ref.read(approvalInboxProvider.notifier).markAwaitingConfirm(e.entryKey);
      },
    ).whenComplete(() => _onSheetClosed(e.entryKey)));
  }

  void _openApprovalCardSheet(
      BuildContext navCtx, InboxEntry e, Widget header) {
    final api = ref.read(apiProvider);
    final auth = ref.read(authProvider);
    final isDark = Theme.of(navCtx).brightness == Brightness.dark;
    final rc = MessageRenderContext(
      isMe: false,
      baseUrl: api.baseUrl,
      token: auth.token ?? '',
      isDark: isDark,
      convId: e.convId,
      messageId: e.msgId,
    );
    unawaited(showModalBottomSheet<void>(
      context: navCtx,
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
