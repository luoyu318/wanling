import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// 聊天输入的待发送附件(挂载预览,图片/文件二选一,再选=替换)。
///
/// 放 APP 层而非 chatProvider(ChatState 在 wanling_core):AssetEntity 来自
/// photo_manager 原生插件,core 包禁止新增原生依赖(desktop 共用)。
/// family key 与 chatProvider 一致,按会话隔离、离开聊天页 autoDispose。
sealed class PendingAttachment {
  const PendingAttachment();
}

/// 相册选图/拍照:实体懒加载(file 为 Future),缩略图走本地 AssetEntityImageProvider。
class PendingImageAsset extends PendingAttachment {
  final AssetEntity asset;
  const PendingImageAsset(this.asset);
}

/// 文件选择器选中的文件:本地路径直接可传,带文件名与字节大小。
class PendingFileAttachment extends PendingAttachment {
  final String path;
  final String name;
  final int size;
  const PendingFileAttachment({
    required this.path,
    required this.name,
    required this.size,
  });
}

final pendingAttachmentProvider = StateProvider.autoDispose
    .family<PendingAttachment?, ({String convId, String? agentId})>(
        (ref, key) => null);
