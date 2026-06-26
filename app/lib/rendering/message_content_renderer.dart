import 'package:flutter/widgets.dart';

import '../models/message.dart';
import '../models/msg_type.dart';

/// 消息内容渲染器接口。
///
/// 每种 [MsgType] 对应一个 [MessageContentRenderer]，负责把消息 content JSON
/// 渲染成内容 widget。MessageBubble 只负责外壳（气泡三角/选择态/勾选框），
/// 把内容渲染委托给 [ContentRendererRegistry] 查到的 renderer。
///
/// 设计动机：后续要支持 HTML 渲染、事件卡片（带按钮）等富内容类型，依赖单一
/// 三方库难以实现。注册表模式让新增类型只需写一个 renderer 并注册，不改
/// MessageBubble。
///
/// 选择控制：是否参与文字选择由 [selectable] 决定。实际的 SelectableRegion
/// 由 MessageBubble 外层统一持有（避免各 renderer 各自包 SelectionArea 导致
/// 嵌套冲突）。text/markdown 可选，image/file 不可选。
///
/// 气泡外壳：[wrapInBubble] 决定 MessageBubble 是否给内容包 [BubbleWithTail]
/// （带三角的气泡）。text/markdown/file 包（=true），image 不包（=false，
/// 图片自带圆角无三角）。
abstract class MessageContentRenderer {
  /// 是否参与文字选择。
  bool get selectable;

  /// 是否由 MessageBubble 包 [BubbleWithTail] 气泡外壳。
  bool get wrapInBubble;

  /// 渲染内容 widget（不含气泡外壳、不含选择容器）。
  ///
  /// [content] 是消息的 content JSONB（形如 {msg_type, data}）。renderer 从中
  /// 取出自己需要的字段。[isMe] 用于区分自己/对方消息（部分 renderer 需要，
  /// 如 FileBubble 的三角方向）。
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext renderContext,
  );
}

/// 传给 renderer 的渲染上下文。
///
/// 把 MessageBubble 的运行时信息（isMe、baseUrl、token、明暗主题）打包传入，
/// 避免每个 renderer 签名都列一长串参数。后续扩展（如富媒体需要的额外上下文）
/// 加字段即可。
class MessageRenderContext {
  final bool isMe;
  final String baseUrl;
  final String token;
  final bool isDark;

  /// 当前会话的全部消息（用于画廊收集会话级图片）。仅点击图片时使用。
  /// 默认空列表，保证 renderer 在测试/无画廊场景下也能正常构造。
  final List<ChatMessage> conversationMessages;

  /// 点击图片时打开画廊的回调。参数是被点击图的 fileId（用于定位初始索引）。
  /// null 表示当前不支持画廊（如测试场景），点击降级为无操作。
  final void Function(String fileId)? openGallery;

  const MessageRenderContext({
    required this.isMe,
    required this.baseUrl,
    required this.token,
    required this.isDark,
    this.conversationMessages = const [],
    this.openGallery,
  });
}

/// 渲染器注册表：[MsgType] → [MessageContentRenderer]。
///
/// 单例静态 map，应用启动时注册所有内置 renderer（见 [registerDefaults]）。
/// 后续扩展（HTML/卡片）时调用 [register] 即可，无需改动 MessageBubble。
class ContentRendererRegistry {
  ContentRendererRegistry._();

  static final Map<MsgType, MessageContentRenderer> _map = {};

  /// 注册某类型的渲染器。重复注册覆盖旧值（便于测试隔离）。
  static void register(MsgType type, MessageContentRenderer renderer) {
    _map[type] = renderer;
  }

  /// 查某类型的渲染器；未注册返回 null。
  static MessageContentRenderer? get(MsgType type) => _map[type];

  /// 渲染指定类型的内容。未注册的类型降级到 [UnknownRenderer]。
  ///
  /// 不返回 null，保证 MessageBubble 一定能拿到一个 widget。
  static Widget render(
    MsgType type,
    Map<String, dynamic> content,
    BuildContext context,
    MessageRenderContext renderContext,
  ) {
    return (_map[type] ?? UnknownRenderer())
        .build(context, content, renderContext);
  }

  /// 判断某类型是否可参与文字选择（便捷封装，避免拿 renderer 再判空）。
  static bool isSelectable(MsgType type) =>
      _map[type]?.selectable ?? false;

  /// 判断某类型是否需要气泡外壳。
  static bool shouldWrapInBubble(MsgType type) =>
      _map[type]?.wrapInBubble ?? true;

  /// 清空注册表。仅供测试重置用，生产代码勿调。
  static void reset() => _map.clear();
}

/// 未知类型的兜底渲染器：把 content 原样 toString 显示。
///
/// 不参与选择（selectable=false），保证即使收到无法识别的 msg_type 也不崩溃。
class UnknownRenderer implements MessageContentRenderer {
  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => true;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext renderContext,
  ) {
    return Text(content.toString());
  }
}
