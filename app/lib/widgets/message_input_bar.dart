import 'package:flutter/material.dart';

import '../utils/emoji_editing_controller.dart';
import 'feedback/app_text_selection_toolbar.dart';
import 'panel_item.dart';

/// 全局 key：让 AppSnackBar 定位到当前页面的 MessageInputBar，
/// 提示条贴输入栏上方显示。MessageInputBar 不存在的页面（如设置页）
/// currentContext 为 null，AppSnackBar 降级贴底 + SafeArea。
final GlobalKey inputBarKey = GlobalKey();

/// IM 风聊天输入栏。
///
/// 内聚状态:输入文本 / 焦点 / 面板显隐 / 加号↔发送切换。
/// 对外只暴露 5 个回调,不依赖任何 Provider。
/// 上传逻辑(拍照/相册/图片/文件)由 ChatPage 通过回调实现。
class MessageInputBar extends StatefulWidget {
  final ValueChanged<String> onSend;
  final VoidCallback onPickFile;
  final VoidCallback onTakePhoto;
  final VoidCallback onPickAlbum;

  const MessageInputBar({
    super.key,
    required this.onSend,
    required this.onPickFile,
    required this.onTakePhoto,
    required this.onPickAlbum,
  });

  @override
  State<MessageInputBar> createState() => _MessageInputBarState();
}

class _MessageInputBarState extends State<MessageInputBar> {
  final EmojiEditingController _inputCtrl = EmojiEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _showPanel = false;
  String _text = '';

  bool get _showSendButton => _text.trim().isNotEmpty;

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
    if (text.isEmpty) return;
    widget.onSend(text);
    _inputCtrl.clear();
    setState(() {
      _text = '';
      _showPanel = false;
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
    // 外层 GestureDetector:点输入框之外的区域(键盘区除外)收键盘。
    // onTap 空实现仍触发命中,配合内部 TextField 的 FocusNode unfocus。
    // KeyedSubtree 挂 inputBarKey：AppSnackBar 通过此 key 定位输入栏位置，
    // 提示条贴输入栏上方显示。用 KeyedSubtree 避免改 GestureDetector 的 key。
    return KeyedSubtree(
      key: inputBarKey,
      child: GestureDetector(
      onTap: () => _focusNode.unfocus(),
      // 颜色 Container 放 SafeArea 外层,确保 SafeArea 的 bottom 安全区
      // (系统导航栏高度)也被填满,不露 Scaffold 背景。
      child: ColoredBox(
        color: const Color(0xFFF7F7F7),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 顶部细线:分隔聊天区与输入栏(同 AppBar 下边框)
              Container(height: 0.5, color: const Color(0xFFD9D9D9)),
              // 输入行:左右内边距,加号垂直居中输入框
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: _buildInputField()),
                    const SizedBox(width: 8),
                    _buildRightButton(),
                  ],
                ),
              ),
              // 面板:全宽铺满,无左右缝隙
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                child: _showPanel
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 输入行与面板之间的分割线(仅面板展开时)
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
          ),
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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
      ),
      child: TextField(
        controller: _inputCtrl,
        focusNode: _focusNode,
        maxLines: null,
        minLines: 1,
        // isDense: 去掉 Material 默认额外间距,让单行高度贴近文字+padding。
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w300, height: 1.0),
        decoration: const InputDecoration(
          isDense: true,
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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

  Widget _buildRightButton() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 150),
      child: _showSendButton
          ? _SendButton(key: const ValueKey('send'), onTap: _onSend)
          : _PlusButton(key: const ValueKey('plus'), onTap: _togglePanel),
    );
  }
}

/// 右侧加号按钮(空内容时显示)。
class _PlusButton extends StatelessWidget {
  final VoidCallback onTap;
  const _PlusButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black),
        ),
        child: const Icon(Icons.add, color: Colors.black, size: 20),
      ),
    );
  }
}

/// 右侧发送按钮(有内容时显示)。
class _SendButton extends StatelessWidget {
  final VoidCallback onTap;
  const _SendButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF07C160),
          borderRadius: BorderRadius.circular(6),
        ),
        alignment: Alignment.center,
        child: const Text(
          '发送',
          style: TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w500),
        ),
      ),
    );
  }
}

/// 加号面板:九宫格(拍照/相册/文件)。
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
