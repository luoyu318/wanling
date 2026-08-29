import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';

/// 聊天输入的待发送图片(选图挂载预览)。
///
/// 放 APP 层而非 chatProvider(ChatState 在 wanling_core):AssetEntity 来自
/// photo_manager 原生插件,core 包禁止新增原生依赖(desktop 共用)。
/// family key 与 chatProvider 一致,按会话隔离、离开聊天页 autoDispose。
final pendingImageProvider = StateProvider.autoDispose
    .family<AssetEntity?, ({String convId, String? agentId})>(
        (ref, key) => null);
