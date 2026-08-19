import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/msg_type.dart' show MsgType;
import 'package:wanling_core/models/participant.dart' show Participant;
import 'package:wanling_core/models/slash_command.dart' show SlashCommand;
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart'
    show ChatNotifier, chatProvider;
import 'package:wanling_core/providers/participant_provider.dart'
    show participantProvider;
import 'package:wanling_core/utils/file_format.dart' show mimeFromExt;
import 'input_toolbar.dart';
import 'mention_panel.dart';
import 'slash_panel.dart';

/// 图片扩展名集合:决定 sendFile 的 msgType(image/file),
/// 仅影响本地乐观消息渲染分支(对齐 app 壳 input_controller,服务端幂等处理)。
const _imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp'};

/// 光标前连续非空白段以 [trigger] 开头 → 返回段起始位置与段文本。
/// 例:文本 "foo /mod" 光标在末尾 + trigger '/' → (start:4, token:"/mod")。
/// "./run.sh" 首字符 '.' 不匹配,"https://x" 段首 'h' 不匹配,防误触发。
({int start, String token})? _tokenBeforeCaret(
    String text, int caret, String trigger) {
  if (caret <= 0 || caret > text.length) return null;
  var s = caret;
  while (s > 0) {
    final ch = text.codeUnitAt(s - 1);
    if (ch == 0x20 || ch == 0x09 || ch == 0x0A) break;
    s--;
  }
  if (s == caret) return null;
  final token = text.substring(s, caret);
  if (!token.startsWith(trigger)) return null;
  return (start: s, token: token);
}

/// 桌面输入区:工具栏上置(📎 文件 / @ 提及 / / 斜杠 / 🖼️ 图片)+ 多行输入框。
///
/// - Enter 发送 / Shift+Enter 换行(IME 组词期间 Enter 放行给输入法)
/// - 输入 `/xxx` 弹 slash 面板(仅 agent 会话,catalog initState 拉取缓存);
///   Enter/点击选中 → 填命令标签(chip),输 args 后 Enter 走 [ChatNotifier.sendSlash]
/// - 输入 `@xxx` 弹提及面板(core participantProvider 数据源),
///   选中把触发词替换为 `@昵称 `(纯文本,@ 无独立协议字段)
/// - 面板用 OverlayEntry + CompositedTransformFollower 定位输入框上方(桌面惯例)
/// - [filePicker] 注入点:测试传 fake 不弹原生选框,生产走 FilePicker.pickFiles
class DesktopInputBar extends ConsumerStatefulWidget {
  final String convId;
  final String? agentId;
  final Future<FilePickerResult?> Function(FileType type)? filePicker;

  const DesktopInputBar({
    super.key,
    required this.convId,
    this.agentId,
    this.filePicker,
  });

  @override
  ConsumerState<DesktopInputBar> createState() => _DesktopInputBarState();
}

class _DesktopInputBarState extends ConsumerState<DesktopInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _layerLink = LayerLink();

  /// slash catalog(agent 会话 initState 拉取;非 agent 会话恒空)。
  List<SlashCommand> _catalog = const [];

  /// 提及数据源(build 时从 participantProvider 同步)。
  List<Participant> _participants = const [];

  /// 选中的 slash 命令(标签模式):发送走 sendSlash(name, args=输入文本)。
  SlashCommand? _pendingSlash;

  /// 当前面板过滤结果(同一时刻至多一个非空,非空即面板显示中)。
  List<SlashCommand>? _slashItems;
  List<Participant>? _mentionItems;
  int _highlight = 0;
  OverlayEntry? _panelEntry;

  ChatNotifier get _chat => ref.read(
        chatProvider((convId: widget.convId, agentId: widget.agentId)).notifier,
      );

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    final aid = widget.agentId;
    if (aid != null) {
      // catalog 拉取失败 fail silent(debugPrint),不弹提示不打扰输入
      // (对齐 app 壳 chat_page._loadSlashCatalog 策略)。
      ref
          .read(apiProvider)
          .getAgentSlashCatalog(aid)
          .then<void>((cmds) {
        if (mounted) setState(() => _catalog = cmds);
      }, onError: (Object e) {
        debugPrint('[desktop_input] slash catalog 加载失败: $e');
      });
    }
  }

  @override
  void dispose() {
    _removePanel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ============ 输入变化 → 面板显隐/过滤 ============

  void _onTextChanged() {
    _refreshPanel();
    if (mounted) setState(() {});
  }

  /// 重算触发词 + 过滤结果,同步 Overlay(slash 优先于 mention)。
  void _refreshPanel() {
    final text = _controller.text;
    final caret = _controller.selection.baseOffset;

    List<SlashCommand>? slash;
    if (widget.agentId != null && _catalog.isNotEmpty && _pendingSlash == null) {
      final token = _tokenBeforeCaret(text, caret, '/');
      if (token != null) {
        final q = token.token.substring(1).toLowerCase();
        final items = _catalog.where((c) {
          return c.name.toLowerCase().contains(q) ||
              c.description.toLowerCase().contains(q);
        }).toList();
        if (items.isNotEmpty) slash = items;
      }
    }

    List<Participant>? mention;
    if (slash == null && _participants.isNotEmpty) {
      final token = _tokenBeforeCaret(text, caret, '@');
      if (token != null) {
        final q = token.token.substring(1).toLowerCase();
        final items = _participants.where((p) {
          return p.displayName.toLowerCase().contains(q) ||
              p.username.toLowerCase().contains(q);
        }).toList();
        if (items.isNotEmpty) mention = items;
      }
    }

    // 面板类型切换或过滤词变化 → 高亮复位首项
    final kindChanged = (slash != null) != (_slashItems != null) ||
        (mention != null) != (_mentionItems != null);
    if (kindChanged) _highlight = 0;
    _slashItems = slash;
    _mentionItems = mention;
    _syncOverlay();
  }

  void _syncOverlay() {
    final show = _slashItems != null || _mentionItems != null;
    if (!show) {
      _removePanel();
      return;
    }
    final entry = _panelEntry;
    if (entry == null) {
      _highlight = 0;
      _panelEntry = OverlayEntry(builder: (_) => _buildOverlayPanel());
      Overlay.of(context).insert(_panelEntry!);
    } else {
      entry.markNeedsBuild();
    }
  }

  void _removePanel() {
    _panelEntry?.remove();
    _panelEntry = null;
    _slashItems = null;
    _mentionItems = null;
  }

  /// Overlay 内容:全屏 barrier(点击面板外关闭)+ LayerLink 锚定输入框上方面板。
  Widget _buildOverlayPanel() {
    return Stack(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _closePanelFromBarrier,
          child: const SizedBox.expand(),
        ),
        CompositedTransformFollower(
          link: _layerLink,
          targetAnchor: Alignment.bottomLeft,
          followerAnchor: Alignment.topLeft,
          offset: const Offset(0, -6),
          child: _slashItems != null
              ? SlashPanel(
                  commands: _slashItems!,
                  highlightedIndex: _highlight,
                  onHover: (i) => _setHighlight(i),
                  onSelected: _applySlash,
                )
              : MentionPanel(
                  members: _mentionItems!,
                  highlightedIndex: _highlight,
                  onHover: (i) => _setHighlight(i),
                  onSelected: _applyMention,
                ),
        ),
      ],
    );
  }

  void _closePanelFromBarrier() {
    _removePanel();
    setState(() {});
  }

  void _setHighlight(int i) {
    if (_highlight == i) return;
    _highlight = i;
    _panelEntry?.markNeedsBuild();
  }

  // ============ 键盘:Enter 发送 / Shift+Enter 换行 / 面板导航 ============

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    // 只处理 KeyDown:KeyRepeatEvent 非 KeyDown 子类,自动长按连发被忽略。
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final enter = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;

    if (_panelEntry != null) {
      final count = _slashItems?.length ?? _mentionItems?.length ?? 0;
      if (key == LogicalKeyboardKey.arrowDown && count > 0) {
        _setHighlight((_highlight + 1) % count);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp && count > 0) {
        _setHighlight((_highlight - 1 + count) % count);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _closePanelFromBarrier();
        return KeyEventResult.handled;
      }
      if (enter) {
        _selectHighlighted();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (enter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _insertNewline();
        return KeyEventResult.handled;
      }
      // 中文 IME 组词期间的 Enter 交给输入法提交组词,不触发发送。
      if (_controller.value.composing.isValid) return KeyEventResult.ignored;
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Shift+Enter:在光标处插入换行(返回 handled,桌面端 IME 不再重复插入)。
  void _insertNewline() {
    final value = _controller.value;
    final caret = value.selection.baseOffset;
    final pos = caret >= 0 ? caret : value.text.length;
    final next = value.text.replaceRange(pos, pos, '\n');
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: pos + 1),
    );
  }

  void _selectHighlighted() {
    final slash = _slashItems;
    if (slash != null) {
      if (_highlight < slash.length) _applySlash(slash[_highlight]);
      return;
    }
    final mention = _mentionItems;
    if (mention != null && _highlight < mention.length) {
      _applyMention(mention[_highlight]);
    }
  }

  // ============ 选中动作 ============

  /// slash 选中 → 标签模式:chip + 清文本 + 聚焦等 args
  /// (对齐 app 壳 MessageInputBar.setSlash 交互)。
  void _applySlash(SlashCommand cmd) {
    _removePanel();
    setState(() {
      _pendingSlash = cmd;
      _controller.clear();
    });
    _focusNode.requestFocus();
  }

  /// mention 选中 → 把 @触发词 替换为 `@昵称 `(纯文本发送,@ 无独立协议)。
  void _applyMention(Participant p) {
    final caret = _controller.selection.baseOffset;
    final token =
        _tokenBeforeCaret(_controller.text, caret, '@');
    _removePanel();
    setState(() {});
    if (token == null) return;
    final insertion = '@${p.displayName} ';
    final next =
        _controller.text.replaceRange(token.start, caret, insertion);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
          offset: token.start + insertion.length),
    );
  }

  // ============ 工具栏动作 ============

  /// @ / 按钮:光标处插入触发字符(必要时前置空格分隔),弹出对应面板。
  void _insertTrigger(String trigger) {
    final text = _controller.text;
    final caret = _controller.selection.baseOffset;
    final pos = caret >= 0 ? caret : text.length;
    final needsSpace = pos > 0 && text.codeUnitAt(pos - 1) != 0x20;
    final s = needsSpace ? ' $trigger' : trigger;
    _controller.value = TextEditingValue(
      text: text.replaceRange(pos, pos, s),
      selection: TextSelection.collapsed(offset: pos + s.length),
    );
    _focusNode.requestFocus();
  }

  /// 📎/🖼️:file_picker 选文件 → core uploadFile(带 convId 授权)→ sendFile。
  /// 扩展名判定 image/file(对齐 app 壳 pickFile 链路)。
  Future<void> _pickAndSend(FileType type) async {
    final pick =
        widget.filePicker ?? (FileType t) => FilePicker.pickFiles(type: t);
    try {
      final result = await pick(type);
      if (!mounted || result == null || result.files.isEmpty) return;
      final f = result.files.first;
      final path = f.path;
      if (path == null || path.isEmpty) {
        _snack('无法读取所选文件');
        return;
      }
      final fileId =
          await ref.read(apiProvider).uploadFile(path, convId: widget.convId);
      if (!mounted) return;
      final lower = path.toLowerCase();
      final dot = lower.lastIndexOf('.');
      final ext = dot >= 0 ? lower.substring(dot) : '';
      final msgType =
          _imageExts.contains(ext) ? MsgType.image : MsgType.file;
      _chat.sendFile(
        fileId,
        msgType,
        filename: f.name,
        mimeType: mimeFromExt(ext),
        fileSize: f.size,
      );
    } catch (e) {
      // fail fast 提示用户,不吞异常细节
      if (mounted) _snack('发送失败: $e');
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        width: 320,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ============ 发送 ============

  void _send() {
    final slash = _pendingSlash;
    final text = _controller.text.trim();
    if (slash != null) {
      _chat.sendSlash(slash.name, text);
    } else if (text.isEmpty) {
      return;
    } else {
      _chat.sendText(text);
    }
    setState(() => _pendingSlash = null);
    _controller.clear();
    _focusNode.requestFocus();
  }

  // ============ build ============

  @override
  Widget build(BuildContext context) {
    final participants = ref.watch(participantProvider(widget.convId));
    if (participants != _participants) {
      _participants = participants;
      // build 期不可动 Overlay,postFrame 重算面板过滤
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refreshPanel();
      });
    }
    final scheme = Theme.of(context).colorScheme;
    final canSend =
        _pendingSlash != null || _controller.text.trim().isNotEmpty;

    return CompositedTransformTarget(
      link: _layerLink,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(10, 4, 6, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InputToolbar(
              onPickFile: () => _pickAndSend(FileType.any),
              onPickImage: () => _pickAndSend(FileType.image),
              onMention: () => _insertTrigger('@'),
              onSlash: () => _insertTrigger('/'),
              slashEnabled: widget.agentId != null && _catalog.isNotEmpty,
            ),
            if (_pendingSlash != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _buildSlashChip(_pendingSlash!),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Focus(
                    onKeyEvent: _handleKey,
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 140),
                      child: TextField(
                        key: const ValueKey('desktop_input_field'),
                        controller: _controller,
                        focusNode: _focusNode,
                        maxLines: null,
                        minLines: 1,
                        style: const TextStyle(fontSize: 13.5, height: 1.3),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 7),
                          hintText: '给万灵下达指令…',
                          hintStyle: TextStyle(
                            fontSize: 13.5,
                            color: scheme.onSurface.withValues(alpha: 0.3),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 30,
                  height: 30,
                  child: IconButton(
                    key: const ValueKey('input_send'),
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    icon: Icon(
                      Icons.send_outlined,
                      color: canSend
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.3),
                    ),
                    onPressed: canSend ? _send : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// slash 命令胶囊:╳ 取消标签并清空文本(对齐 app 壳 chip 交互)。
  Widget _buildSlashChip(SlashCommand cmd) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const ValueKey('slash_chip'),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '/${cmd.name}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              onTap: () => setState(() {
                _pendingSlash = null;
                _controller.clear();
              }),
              borderRadius: BorderRadius.circular(8),
              child: Icon(
                Icons.close,
                size: 13,
                color: scheme.onSurface.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
