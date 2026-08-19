import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/quote.dart';

/// 用户选择的 model override（chat_provider.selectModel 设置）。
/// 字段命名用 camelCase（chat_provider 内部用），转 WS 协议 snake_case 在 sendText 处。
class ModelOverride {
  final String providerID;
  final String modelID;
  final String? modelName;
  final String? providerName;

  const ModelOverride({
    required this.providerID,
    required this.modelID,
    this.modelName,
    this.providerName,
  });
}

/// 聊天页面状态。包含消息列表 + 未读导航状态。
class ChatState {
  /// 历史 sliver 消息(newest-first,[0]=最新历史贴近锚点,末尾=最老)。
  /// _initialize / loadMoreHistory / mergeJumpedContext 写入。
  final List<ChatMessage> historyMessages;

  /// 活跃 sliver 消息(oldest-first,[0]=最旧活跃贴近锚点,末尾=最新)。
  /// 会话期间发送/接收/流式 add() 末尾。退出页面 autoDispose 重置。
  final List<ChatMessage> liveMessages;

  /// 显示用合并视图(newest-first,与历史 messages 字段语义等价):
  /// 合并 live + history → 按 createdAt 全局降序 → 按 id 去重(保留首次=最新版本)。
  ///
  /// 生产中 live 消息恒比 history 新(实时消息时间戳 > 进入会话时加载的历史),
  /// 全局排序与「分段 [live.reversed, history]」结果一致;mergeJumpedContext /
  /// jumpToBottom reload 等场景下 history 可能短暂含与 live 同 id 的消息
  /// (history 是 server reload 版本),去重保留 createdAt 更新者。
  /// 消费方需要「扁平 newest-first 列表」时用此 getter(index/indexWhere/length/first)。
  /// 双 sliver 渲染不经过此 getter(直接读 liveMessages/historyMessages)。
  List<ChatMessage> get displayMessages {
    final all = [...liveMessages, ...historyMessages];
    all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final seen = <String>{};
    return all.where((m) => seen.add(m.id)).toList();
  }

  final bool isLoadingMore;
  final bool hasMore;
  final int unreadCount;                // 未读数（历史未读 + 会话内新消息合并）
  final String? firstUnreadMessageId;   // 第一条未读消息 ID
  final bool showUnreadSeparator;       // 是否显示未读分隔线

  /// 首屏初始化中（_initialize 期间为 true）。
  /// 用于 ChatPage 显示 loading overlay：
  /// loading 期间 ListView 仍在树里（itemCount=0），让 ListViewObserver 的
  /// PostFrameCallback 提前注册 sliverContexts；state ready 后触发 jumpTo 时
  /// sliverContexts 已就绪，jumpTo 才能正常工作（修复 Bug A）。
  ///
  /// 注意:DB eager hit(F4)会提前设 false 以即时呈现消息,但此时 server 的
  /// getConversation/getUnreadInfo 尚未完成,convType/sessionMeta 未就绪。
  /// 依赖「server 初始化完成」的逻辑(如 pendingInitialScroll 定位)应改用
  /// [isServerInitialized],否则会在底部输入区尚未稳定(convType 未定 →
  /// strip 未挂载)时过早定位,导致最新消息被后续挂载的 strip 遮挡。
  final bool isInitialLoading;

  /// server 端 _initialize 是否完成(getConversation + getUnreadInfo + getMessages)。
  /// DB eager hit 只设 [isInitialLoading]=false,本字段保持 false;
  /// server 三分支完成后才置 true。pendingInitialScroll 等底部输入区稳定
  /// (convType/sessionMeta 就绪)的定位逻辑以此为准,避免过早 jumpTo。
  final bool isServerInitialized;

  /// 待发送引用消息（user 长按消息选「引用」后设置）。
  /// 输入栏预览此字段,发送时合并到 content.data.quote.message_id,然后清空。
  /// null 表示无待发送引用。
  /// 不放 ChatNotifier 实例字段:StateNotifier 通过 state 变化通知 UI,
  /// 实例字段不会触发 rebuild。
  final Quote? pendingQuote;

  /// 会话类型（如 'dm_user_agent' / 'agent_session' / 'group_user'）。
  /// _initialize 时从 server 拉取，用于 conversationProvider 未包含的会话
  /// （agent_session 被 ListForUser 排除，ChatPage 需另取 type 走排版分支）。
  /// null = 未加载（首帧过渡态）。
  final String? convType;

  /// 会话显示名（_initialize 从 getConversation 拉取）。
  /// agent_session 被 conversationProvider 排除，AppBar title 用此字段兜底。
  final String? convTitle;

  /// agent_session 元数据（mode/model/git_branch/tokens），从 getConversation 拉取。
  /// ChatPage 据此渲染副标题「Build · glm-5.2 zhipuai-coding-plan · max」。
  /// 注意:cwd 不在 session_meta(已升级到 conversations.directory 一级列)。
  final SessionMeta? sessionMeta;

  /// agent_session 工作目录(从 conversations.directory 一级列拉取)。
  /// EnvMetaStrip 的 cwd 段从这里读,不再读 sessionMeta.cwd。
  final String? directory;

  /// APP 端点击切换的 mode 覆盖（build↔plan）。
  /// null = 用 sessionMeta.mode；非 null = 用户手动切换。
  /// _refreshSessionMeta 拉取后如果与 server mode 不同则清除（OC 优先）。
  final String? modeOverride;

  /// APP 端点击切换的 model 覆盖。
  /// null = 用 sessionMeta.modelId；非 null = 用户手动选择。
  /// _refreshSessionMeta 拉取后如果与 server model 一致则清除（OC 优先）。
  final ModelOverride? modelOverride;

  const ChatState({
    this.historyMessages = const [],
    this.liveMessages = const [],
    this.isLoadingMore = false,
    this.hasMore = true,
    this.unreadCount = 0,
    this.firstUnreadMessageId,
    this.showUnreadSeparator = false,
    this.isInitialLoading = true,
    this.isServerInitialized = false,
    this.pendingQuote,
    this.convType,
    this.convTitle,
    this.sessionMeta,
    this.directory,
    this.modeOverride,
    this.modelOverride,
  });

  /// 未读浮标是否显示：还有剩余未读就显示（随上滑阅读递减到 0 才消失）。
  bool get shouldShowUnreadBadge => unreadCount > 0;

  ChatState copyWith({
    List<ChatMessage>? historyMessages,
    List<ChatMessage>? liveMessages,
    bool? isLoadingMore,
    bool? hasMore,
    int? unreadCount,
    String? firstUnreadMessageId,
    bool clearFirstUnread = false,
    bool? showUnreadSeparator,
    bool? isInitialLoading,
    bool? isServerInitialized,
    Quote? pendingQuote,
    bool clearPendingQuote = false,
    String? convType,
    String? convTitle,
    SessionMeta? sessionMeta,
    String? directory,
    String? modeOverride,
    bool clearModeOverride = false,
    ModelOverride? modelOverride,
    bool clearModelOverride = false,
  }) {
    return ChatState(
      historyMessages: historyMessages ?? this.historyMessages,
      liveMessages: liveMessages ?? this.liveMessages,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      unreadCount: unreadCount ?? this.unreadCount,
      firstUnreadMessageId: clearFirstUnread
          ? null
          : (firstUnreadMessageId ?? this.firstUnreadMessageId),
      showUnreadSeparator: showUnreadSeparator ?? this.showUnreadSeparator,
      isInitialLoading: isInitialLoading ?? this.isInitialLoading,
      isServerInitialized:
          isServerInitialized ?? this.isServerInitialized,
      pendingQuote:
          clearPendingQuote ? null : (pendingQuote ?? this.pendingQuote),
      convType: convType ?? this.convType,
      convTitle: convTitle ?? this.convTitle,
      sessionMeta: sessionMeta ?? this.sessionMeta,
      directory: directory ?? this.directory,
      modeOverride:
          clearModeOverride ? null : (modeOverride ?? this.modeOverride),
      modelOverride:
          clearModelOverride ? null : (modelOverride ?? this.modelOverride),
    );
  }
}
