import 'package:flutter/material.dart';

import 'package:wanling_core/models/slash_command.dart';
import 'package:wanling_core/utils/emoji_editing_controller.dart';
import '../feedback/app_text_selection_toolbar.dart';
import '../panel_item.dart';

/// IM 风聊天输入栏。
///
/// 内聚状态:输入文本 / 焦点 / 面板显隐 / 加号↔发送切换。
/// 对外只暴露 5 个回调,不依赖任何 Provider。
/// 上传逻辑(拍照/相册/图片/文件)由 ChatPage 通过回调实现。
///
/// agent_session 定制参数(参见 v5 设计图):
/// - [backgroundColor] 纯白背景
/// - [flatInput] 输入框去 decoration 融入背景
/// - [modeBarColor] 左侧 4px 贯穿竖线颜色(Build/Plan)
/// - [middleSlot] 输入框与面板之间的 session meta 条
class MessageInputBar extends StatefulWidget {
  final ValueChanged<String> onSend;
  final VoidCallback onPickFile;
  final VoidCallback onTakePhoto;
  final VoidCallback onPickAlbum;
  /// 顶部覆盖层(可选)。
  /// 渲染在分割线之上、输入行之上的额外槽位,默认 null 时不渲染。
  /// 用于接入引用预览条(QuotePreviewBar)。
  final Widget? topOverlay;
  /// 输入区域背景色。默认 #F7F7F7，agent_session 传纯白。
  final Color backgroundColor;
  /// 输入框去 decoration（白底圆角），融入背景。默认 false。
  final bool flatInput;
  /// 左侧模式竖线颜色。null=不显示（dm/群聊），agent_session 传模式色。
  final Color? modeBarColor;
  /// 是否渲染左侧模式竖线。agent_session 竖线已上提到 chat_page Stack，输入栏自身不重复渲染。
  final bool showModeBar;
  /// 按钮强调色（发送/加号）。null 时回退 modeBarColor。
  final Color? accentColor;
  /// 输入框与面板之间的插槽（session meta 条）。
  final Widget? middleSlot;
  /// 输入行之上的插槽（StopBar 用）。渲染在 topOverlay 之下、输入行之上。
  final Widget? topSlot;
  /// 选了 slash 命令后,发送时触发(传命令名 + 用户输入的 args)。
  /// 仅 agent_session 用,dm/群聊为 null。
  final void Function(String name, String args)? onSendSlash;
  /// 有待发送图片挂载:发送按钮常显,且允许空文字触发 onSend('')。
  final bool hasPendingAttachment;

  const MessageInputBar({
    super.key,
    required this.onSend,
    required this.onPickFile,
    required this.onTakePhoto,
    required this.onPickAlbum,
    this.topOverlay,
    this.backgroundColor = const Color(0xFFF7F7F7),
    this.flatInput = false,
    this.modeBarColor,
    this.showModeBar = true,
    this.accentColor,
    this.middleSlot,
    this.topSlot,
    this.onSendSlash,
    this.hasPendingAttachment = false,
  });

  @override
  State<MessageInputBar> createState() => _MessageInputBarState();
}

class _MessageInputBarState extends State<MessageInputBar> {
  final EmojiEditingController _inputCtrl = EmojiEditingController();
  final FocusNode _focusNode = FocusNode();
  final GlobalKey _inputBarKey = GlobalKey();
  bool _showPanel = false;
  String _text = '';
  SlashCommand? _pendingSlash;

  bool get _showSendButton =>
      _text.trim().isNotEmpty || _pendingSlash != null || widget.hasPendingAttachment;

  @override
  void initState() {
    super.initState();
    _inputCtrl.addListener(_onTextChanged);
    // 输入框获焦→收面板(键盘与面板互斥)
    _focusNode.addListener(_onFocusChanged);
  }

  void _onTextChanged() {
    final next = _inputCtrl.text;
    if (next != _text) {
      setState(() => _text = next);
    }
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus && _showPanel) {
      setState(() => _showPanel = false);
    }
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onSend() {
    final text = _inputCtrl.text.trim();
    if (_pendingSlash != null) {
      // 不变量:_pendingSlash 仅由 setSlash 设置,setSlash 仅通过 InputController.onSetSlash
      // 调用,而 onSetSlash 仅在 chat_page agent_session 分支绑定(那里 onSendSlash 必传)。
      // 因此 _pendingSlash != null 时 onSendSlash 必非空,否则是编程错误,fail fast 暴露。
      // assert 仅 debug 模式触发,release 保持原行为不引入崩溃。
      assert(
        widget.onSendSlash != null,
        '_pendingSlash 仅 agent_session 路径应设置,onSendSlash 必传',
      );
      widget.onSendSlash?.call(_pendingSlash!.name, text);
      setState(() {
        _pendingSlash = null;
      });
    } else {
      if (text.isEmpty && !widget.hasPendingAttachment) return;
      widget.onSend(text);
    }
    _inputCtrl.clear();
    setState(() {
      _text = '';
      _showPanel = false;
    });
  }

  /// 选了 slash 命令后填入标签 + 聚焦等用户输入 args。
  /// 由 InputController.setSlash 转发调用,chat_page 处理 SlashCommandSheet.onSelected。
  void setSlash(SlashCommand cmd) {
    setState(() {
      _pendingSlash = cmd;
      _inputCtrl.text = '';
      _text = '';
    });
    // 异步请求焦点,避免在 build 阶段触发 focus change
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  void _togglePanel() {
    if (_showPanel) {
      // 已展开→收起
      setState(() => _showPanel = false);
    } else {
      // 收键盘→展面板(IM 风互斥,Task 3 接面板 UI)
      _focusNode.unfocus();
      setState(() => _showPanel = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 主内容 Column（两种模式共用）
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.topOverlay != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: widget.topOverlay!,
          ),
        // 顶部细线:dm/群聊保留，agent_session(flatInput)省略
        if (!widget.flatInput)
          Container(height: 0.5, color: const Color(0xFFD9D9D9)),
        // 输入行之上的槽位（StopBar）
        if (widget.topSlot != null) widget.topSlot!,
        // slash 命令胶囊（env strip 下方）
        if (_pendingSlash != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: _buildSlashChip(_pendingSlash!),
          ),
        // 输入行
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: _buildInputField()),
              const SizedBox(width: 8),
              _buildRightButton(),
            ],
          ),
        ),
        // middleSlot（session meta 条）
        if (widget.middleSlot != null) widget.middleSlot!,
        // 面板
        AnimatedSize(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          child: _showPanel
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                        height: 0.5, color: const Color(0xFFD9D9D9)),
                    _PlusPanel(
                      onTakePhoto: () =>
                          _onPanelAction(widget.onTakePhoto),
                      onPickAlbum: () =>
                          _onPanelAction(widget.onPickAlbum),
                      onPickFile: () =>
                          _onPanelAction(widget.onPickFile),
                    ),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ],
    );

    // agent_session：左侧竖线用 Stack+Positioned 贯穿（不影响 AnimatedSize）
    // 竖线已上提到 chat_page Stack 时 showModeBar=false，flatInput 时仍需 left:4 对齐
    final showBar = widget.modeBarColor != null && widget.showModeBar;
    Widget body;
    if (showBar) {
      body = Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: content,
          ),
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(width: 4, color: widget.modeBarColor),
            ),
          ),
        ],
      );
    } else if (widget.flatInput) {
      body = Padding(
        padding: const EdgeInsets.only(left: 4),
        child: content,
      );
    } else {
      body = content;
    }

    return KeyedSubtree(
      key: _inputBarKey,
      child: GestureDetector(
        onTap: () => _focusNode.unfocus(),
        child: ColoredBox(
          color: widget.backgroundColor,
          child: SafeArea(
            top: false,
            child: body,
          ),
        ),
      ),
    );
  }

  /// 面板格点击:触发回调 + 收起面板。
  void _onPanelAction(VoidCallback callback) {
    callback();
    setState(() => _showPanel = false);
  }

  Widget _buildInputField() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 140),
      decoration: widget.flatInput
          ? null
          : BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
            ),
      child: TextField(
        controller: _inputCtrl,
        focusNode: _focusNode,
        maxLines: null,
        minLines: 1,
        // isDense: 去掉 Material 默认额外间距,让单行高度贴近文字+padding。
        style: const TextStyle(
            fontSize: 17, fontWeight: FontWeight.w300, height: 1.2),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding:
              EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          hintText: '给万灵下达指令…',
          hintStyle: TextStyle(color: Color(0xFFBBBBBB), fontSize: 17),
        ),
        // 长按选区弹深色胶囊文字级菜单（统一 AppTextSelectionToolbar 风格）
        contextMenuBuilder: (context, editableTextState) {
          return AppTextSelectionToolbar(
            buttonItems: editableTextState.contextMenuButtonItems,
            anchors: editableTextState.contextMenuAnchors,
          );
        },
      ),
    );
  }

  /// slash 标签胶囊:点击 ╳ 取消 _pendingSlash + 清空文本。
  /// 横向撑满,背景色与发送按钮一致,白字,叉靠右。
  Widget _buildSlashChip(SlashCommand cmd) {
    final chipColor =
        widget.accentColor ?? widget.modeBarColor ?? const Color(0xFF07C160);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: chipColor,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              setState(() {
                _pendingSlash = null;
                _inputCtrl.clear();
                _text = '';
              });
            },
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 12, color: Colors.white),
            ),
          ),
          Flexible(
            child: Text(
              '/${cmd.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightButton() {
    final accent = widget.accentColor ?? widget.modeBarColor;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      child: _showSendButton
          ? _SendButton(key: const ValueKey('send'), onTap: _onSend, color: accent)
          : _PlusButton(key: const ValueKey('plus'), onTap: _togglePanel, color: accent),
    );
  }
}

/// 右侧加号按钮(空内容时显示)。
class _PlusButton extends StatelessWidget {
  final VoidCallback onTap;
  final Color? color;
  const _PlusButton({super.key, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.black;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: c),
        ),
        child: Icon(Icons.add, color: c, size: 20),
      ),
    );
  }
}

/// 右侧发送按钮(有内容时显示)。
class _SendButton extends StatelessWidget {
  final VoidCallback onTap;
  final Color? color;
  const _SendButton({super.key, required this.onTap, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? const Color(0xFF07C160);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: c,
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Transform.rotate(
          angle: -0.78,
          child: const Icon(Icons.send, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}

/// 加号面板:三格(拍照/相册/文件)。
class _PlusPanel extends StatelessWidget {
  final VoidCallback onTakePhoto;
  final VoidCallback onPickAlbum;
  final VoidCallback onPickFile;

  const _PlusPanel({
    required this.onTakePhoto,
    required this.onPickAlbum,
    required this.onPickFile,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
      child: GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 18,
        crossAxisSpacing: 12,
        childAspectRatio: 0.8,
        children: [
          PanelItem(
              icon: Icons.camera_alt_outlined,
              label: '拍照',
              onTap: onTakePhoto),
          PanelItem(
              icon: Icons.photo_outlined, label: '相册', onTap: onPickAlbum),
          PanelItem(
              icon: Icons.insert_drive_file_outlined,
              label: '文件',
              onTap: onPickFile),
        ],
      ),
    );
  }
}
