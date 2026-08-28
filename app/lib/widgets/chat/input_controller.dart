import 'dart:async';

import 'package:app/providers/pending_image_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';

import 'package:wanling_core/models/msg_type.dart' show MsgType;
import 'package:wanling_core/models/slash_command.dart' show SlashCommand;
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart' show ChatNotifier;
import '../../utils/dio_error.dart' show extractDioErrorMessage;
import 'package:wanling_core/utils/file_format.dart' show mimeFromExt;
import 'package:wanling_core/utils/snackbar.dart' show showAppSnackBar, SnackBarType;
import '../avatar_picker.dart' show defaultAssetPickerConfig;

/// 图片扩展名集合：pickFile 据此判定上传结果是 image 还是 file 消息。
/// 与服务端 enhanceContentFromFile 的判定无关（服务端幂等处理 image/file），
/// 仅决定客户端 sendFile 的 msgType，影响本地乐观消息的渲染分支。
const _imageExts = {'.png', '.jpg', '.jpeg', '.gif', '.webp'};

/// [InputController] 的依赖注入容器。
///
/// chat_page 在 initState 构造一次，把所有外部依赖打包传入。controller
/// 内部通过 `_ctx.xxx` 访问，实现解耦 + 可测试性（mock 本对象即可单测）。
@immutable
class InputContext {
  /// 用于 showAppSnackBar / CameraPicker / AssetPicker（需 BuildContext）。
  final BuildContext Function() getContext;

  /// for apiProvider.read（uploadFile 拿 ApiService）。
  final WidgetRef ref;

  /// chatProvider family key（仅用 convId 做 uploadFile 授权）。
  final ({String convId, String? agentId}) chatKey;

  /// dispose 后 false：上传完成回调前用此守卫，避免 setState-after-dispose
  /// 触发的 snackbar 在已卸载的页面上抛异常。
  final bool Function() isMounted;

  /// 拿 ChatNotifier 调 sendText / sendFile。chat_page 用
  /// `ref.read(chatProvider(key).notifier)`。
  final ChatNotifier Function() getNotifier;

  const InputContext({
    required this.getContext,
    required this.ref,
    required this.chatKey,
    required this.isMounted,
    required this.getNotifier,
  });
}

/// 输入栏行为控制器（方案 A：Controller class + 依赖注入）。
///
/// 封装 chat_page 原有的输入相关方法：send / pickFile / takePhoto /
/// pickAlbum。chat_page 在 initState 创建，
/// dispose 时由 GC 回收（无 OverlayEntry / StreamSubscription 等需手动释放）。
///
/// `_buildInputBar` 保留在 chat_page（它依赖 chatState.modeOverride 等 UI 状态），
/// 仅把 4 个 onSend/onPickFile/onTakePhoto/onPickAlbum 回调改成 controller 方法。
class InputController {
  final InputContext _ctx;

  /// send 上传期间防抖(挂图发送是异步上传流程,防双发)。
  bool _sending = false;

  InputController(this._ctx);

  /// slash 标签设置回调，由 chat_page 绑定（转发到 MessageInputBar 的 setSlash 方法）。
  /// 仅 agent_session 会话用，dm/群聊为 null。
  void Function(SlashCommand)? onSetSlash;

  /// 选了 slash 命令后填入输入栏当标签 + 聚焦等用户输入 args。
  /// 由 SlashCommandSheet.onSelected 触发（经 chat_page 转发）。
  void setSlash(SlashCommand cmd) {
    onSetSlash?.call(cmd);
  }

  /// 发送入口(输入栏发送按钮回调)。
  /// 挂图时:上传 → 有文字 sendMixed / 无文字 sendFile(image);失败保留挂图可重试。
  /// 无挂图:维持 sendText 现状(空串 no-op)。
  /// _sending 防抖:上传期间重复点发送直接忽略,防双发。
  Future<void> send(String text) async {
    if (_sending) return;
    final image = _ctx.ref.read(pendingImageProvider(_ctx.chatKey));
    if (image == null) {
      if (text.isEmpty) return;
      unawaited(_ctx.getNotifier().sendText(text));
      return;
    }
    _sending = true;
    try {
      final file = await image.file;
      if (file == null) {
        if (_ctx.isMounted()) {
          showAppSnackBar(_ctx.getContext(), '无法读取文件',
              type: SnackBarType.error);
        }
        return;
      }
      final api = _ctx.ref.read(apiProvider);
      final fileId =
          await api.uploadFile(file.path, convId: _ctx.chatKey.convId);
      // 上传是长耗时异步,期间用户可能点 × 移除挂图或重选新图。
      // 清除前校验 provider 里还是当初捕获的那个 asset:已被移除/替换则不清,
      // 防止已取消的图仍被发出、或重选的新图被静默吞掉。
      final current = _ctx.ref.read(pendingImageProvider(_ctx.chatKey));
      if (identical(current, image)) _clearPendingImage();
      if (text.isNotEmpty) {
        unawaited(_ctx.getNotifier().sendMixed(text, fileId));
      } else {
        unawaited(_ctx.getNotifier().sendFile(fileId, MsgType.image));
      }
    } catch (e) {
      // 失败不清挂图:用户可重试或删除
      if (_ctx.isMounted()) {
        showAppSnackBar(_ctx.getContext(), extractDioErrorMessage(e),
            type: SnackBarType.error);
      }
    } finally {
      _sending = false;
    }
  }

  void _clearPendingImage() {
    _ctx.ref.read(pendingImageProvider(_ctx.chatKey).notifier).state = null;
  }

  /// 选文件（任意类型）：FilePicker → uploadFile → sendFile。
  /// 上传失败 SnackBar 提示（fail fast，不吞异常）。
  Future<void> pickFile() async {
    final result = await FilePicker.pickFiles();
    if (result == null || result.files.isEmpty) return;

    try {
      final api = _ctx.ref.read(apiProvider);
      final file = result.files.first;
      final fileId =
          await api.uploadFile(file.path!, convId: _ctx.chatKey.convId);

      // lastIndexOf('.') 在无扩展名时返回 -1，substring(-1) 会抛 RangeError。
      // 显式取 dotIdx，无点 → 空字符串，由 mimeFromExt 兜底返 octet-stream。
      final lower = file.path!.toLowerCase();
      final dotIdx = lower.lastIndexOf('.');
      final ext = dotIdx >= 0 ? lower.substring(dotIdx) : '';
      final msgType = _imageExts.contains(ext) ? MsgType.image : MsgType.file;
      final mimeType = mimeFromExt(ext);
      unawaited(_ctx.getNotifier().sendFile(
            fileId,
            msgType,
            filename: file.name,
            // image 类型也带 mime_type：服务端 enhanceContentFromFile 对
            // image/file 均幂等处理（已有值跳过），传完整元信息让客户端无网络
            // 往返即可正确展示。
            mimeType: mimeType,
            fileSize: file.size,
          ));
    } catch (e) {
      if (_ctx.isMounted()) {
        showAppSnackBar(_ctx.getContext(), extractDioErrorMessage(e),
            type: SnackBarType.error);
      }
    }
  }

  /// 拍照:产物挂到输入条上方缩略图,不立即发送。
  Future<void> takePhoto() async {
    final asset = await CameraPicker.pickFromCamera(_ctx.getContext());
    if (asset == null) return;
    _ctx.ref.read(pendingImageProvider(_ctx.chatKey).notifier).state = asset;
  }

  /// 相册:选图挂载(再选=替换),不立即发送。
  Future<void> pickAlbum() async {
    final result = await AssetPicker.pickAssets(
      _ctx.getContext(),
      pickerConfig: defaultAssetPickerConfig,
    );
    if (result == null || result.isEmpty) return;
    _ctx.ref.read(pendingImageProvider(_ctx.chatKey).notifier).state =
        result.first;
  }
}
