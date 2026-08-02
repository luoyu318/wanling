import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';

import '../../models/msg_type.dart' show MsgType;
import '../../models/slash_command.dart' show SlashCommand;
import '../../providers/auth_provider.dart' show apiProvider;
import '../../providers/chat_provider.dart' show ChatNotifier;
import '../../utils/dio_error.dart' show extractDioErrorMessage;
import '../../utils/file_format.dart' show mimeFromExt;
import '../../utils/snackbar.dart' show showAppSnackBar, SnackBarType;
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
/// 封装 chat_page 原有的 4 个输入相关方法：send / pickFile / takePhoto /
/// pickAlbum（含共用的 uploadAndSendAsset）。chat_page 在 initState 创建，
/// dispose 时由 GC 回收（无 OverlayEntry / StreamSubscription 等需手动释放）。
///
/// `_buildInputBar` 保留在 chat_page（它依赖 chatState.modeOverride 等 UI 状态），
/// 仅把 4 个 onSend/onPickFile/onTakePhoto/onPickAlbum 回调改成 controller 方法。
class InputController {
  final InputContext _ctx;

  InputController(this._ctx);

  /// slash 标签设置回调，由 chat_page 绑定（转发到 MessageInputBar 的 setSlash 方法）。
  /// 仅 agent_session 会话用，dm/群聊为 null。
  void Function(SlashCommand)? onSetSlash;

  /// 选了 slash 命令后填入输入栏当标签 + 聚焦等用户输入 args。
  /// 由 SlashCommandSheet.onSelected 触发（经 chat_page 转发）。
  void setSlash(SlashCommand cmd) {
    onSetSlash?.call(cmd);
  }

  /// 发送文本。空串 no-op（不让 sendText 收到空消息）。
  void send(String text) {
    if (text.isEmpty) return;
    _ctx.getNotifier().sendText(text);
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
      _ctx.getNotifier().sendFile(
            fileId,
            msgType,
            filename: file.name,
            // image 类型也带 mime_type：服务端 enhanceContentFromFile 对
            // image/file 均幂等处理（已有值跳过），传完整元信息让客户端无网络
            // 往返即可正确展示。
            mimeType: mimeType,
            fileSize: file.size,
          );
    } catch (e) {
      if (_ctx.isMounted()) {
        showAppSnackBar(_ctx.getContext(), extractDioErrorMessage(e),
            type: SnackBarType.error);
      }
    }
  }

  /// 拍照：CameraPicker → uploadAndSendAsset(image)。
  Future<void> takePhoto() async {
    final asset = await CameraPicker.pickFromCamera(_ctx.getContext());
    if (asset == null) return;
    await uploadAndSendAsset(asset, MsgType.image);
  }

  /// 相册：AssetPicker（复用 avatar_picker 共享配置）→ uploadAndSendAsset(image)。
  Future<void> pickAlbum() async {
    final result = await AssetPicker.pickAssets(
      _ctx.getContext(),
      // 复用 avatar_picker 的共享配置（简体中文 + 品牌绿 + 相册名汉化），
      // 避免两处配置漂移。详见 defaultAssetPickerConfig 注释。
      pickerConfig: defaultAssetPickerConfig,
    );
    if (result == null || result.isEmpty) return;
    await uploadAndSendAsset(result.first, MsgType.image);
  }

  /// 把 AssetEntity 写成临时文件 → uploadFile → sendFile。
  /// 失败 SnackBar 提示（fail fast，不吞异常）。
  ///
  /// takePhoto / pickAlbum 共用。public 以便单测直接覆盖（picker 本身是原生
  /// 插件，单测无法触达；本方法是纯 dart 逻辑，可 mock api + fake asset）。
  Future<void> uploadAndSendAsset(AssetEntity asset, MsgType msgType) async {
    final file = await asset.file;
    if (file == null) {
      if (_ctx.isMounted()) {
        showAppSnackBar(_ctx.getContext(), '无法读取文件',
            type: SnackBarType.error);
      }
      return;
    }
    try {
      final api = _ctx.ref.read(apiProvider);
      final fileId =
          await api.uploadFile(file.path, convId: _ctx.chatKey.convId);
      _ctx.getNotifier().sendFile(fileId, msgType);
    } catch (e) {
      if (_ctx.isMounted()) {
        showAppSnackBar(_ctx.getContext(), extractDioErrorMessage(e),
            type: SnackBarType.error);
      }
    }
  }
}
