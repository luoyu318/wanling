# APP Utils

lib/utils/ 工具集合。

## app_lifecycle_observer.dart

监听 app 前后台切换，触发后台服务启停

## avatar_bitmap.dart

通知头像加载（URL 下载 → 裁方形(192x192)+圆角 → 文件缓存；失败兜底首字母色块，复用 `Avatar.colorFor`）。纯函数不依赖 Riverpod，isolate 可用

## dio_error.dart

统一 Dio 异常 → 用户可读文案

## emoji_span.dart + emoji_editing_controller.dart

**Android emoji 单色修复**。背景：Android Roboto 字体 cmap 含 ♻⚠✂ 等单色字形，主字体先抢到会渲染成单色（而非彩色 emoji）。方案：精确 span 分割，只给 emoji 字符段单独设 `fontFamily: 'Noto Color Emoji'`（pubspec 打包字体子集），普通文本仍走 Roboto 度量不受污染。弃用过全局 `fontFamilyFallback`（Noto Color Emoji cmap 含宽空格/宽数字会污染普通文本）。`EmojiEditingController` 是 `TextEditingController` 子类，覆盖 `buildTextSpan` 让输入框也走彩色 emoji

## gallery_image.dart

画廊数据层。`GalleryImage` 模型（url/fileId/headers/heroTag='gallery_$fileId'）；`GalleryImage.fromInternal` 拼**原图** URL（画廊全屏看大图用高清）；`thumbUrl(baseUrl, fileId)` 拼**缩略图** URL（`?thumb=1`，服务端返回 600px 长边小图，无缩略图时自动降级原图，消息列表/气泡/markdown 内嵌图场景用）；`extractInternalImageIds` 用正则从 markdown 提取 `/api/files/{id}`；`collectConversationImages` 遍历会话 image + markdown 消息去重收集，结尾反转（chatProvider 是 newest-first，反转后 index 0 = 最旧）；`saveToGallery` 将画廊图片保存到系统相册（dio 鉴权下载字节，3 秒超时 → `Gal.putImageBytes` 写相册，gal 按 magic bytes 自动推断格式免临时文件，返回 `SaveResult` 枚举，gal 写入免权限）

## image_cache_key.dart

**图片内存缓存 key 统一约定**。`thumbCacheKey(fileId)`='thumb_$fileId'（缩略图场景：消息列表/气泡/markdown 内嵌图共用）；`originCacheKey(fileId)`='origin_$fileId'（画廊原图独用）。key 用稳定前缀+fileId，不含 baseUrl/host，切服务器/账号时同一张图内存缓存仍命中。根治「每次打开重新加载」：缩略图与画廊原图 cacheKey 隔离，避免小 bitmap 把大 bitmap 从 LRU 顶掉；同图多处复用同一 key 不重复解码

## image_normalizer.dart

**头像裁剪 HEIC 黑屏修复**（commit ba9ba25）。把相册选图原始字节转码为标准 JPEG 喂给 `crop_your_image`。解码用 `dart:ui`（Skia 支持全格式含 HEIC），编码用 `image` 包的 `encodeJpg`（dart:ui 无 jpg 格式常量），中间走 RGBA 像素桥接。同时等比缩放到长边 ≤2047px 降内存，Canvas 铺白底防 PNG 透明转 JPEG 黑边。`AvatarPicker` 选图后先 `normalizeImageForCrop` 再喂裁剪库

## notification_payload.dart

通知点击 payload 解析（路由到对应会话）

## permission_helper.dart

`permission_handler` 封装，运行时权限申请（图片/通知）

## secure_storage.dart

AES-256-GCM 加解密 helper(非 `flutter_secure_storage` 封装)。密钥派生:SHA256(`com.wanling.app` | ANDROID_ID | 固定盐) 前 32 字节。换设备/重装失效(ANDROID_ID 变)。`saved_logins_provider` 用于多账号加密存储。**与 `services/secure_storage.dart`(TokenVault) 区分**:后者是 flutter_secure_storage 封装,存 JWT token 凭证;本类是 AES-GCM 加密 helper,存多账号信息。

## snackbar.dart

全局 Snackbar helper

## file_format.dart

**文件大小格式化 + mime 推断**(v1.0.6)。`formatFileSize(int bytes)` 按字节 / KB / MB / GB 分档(1 位小数);`mimeFromExt(String ext)` 16 条扩展名映射(.pdf/.doc(x)/.xls(x)/.ppt(x)/.zip/.txt/.md/.csv/.jpg/.png/.webp/.gif),未知返 `application/octet-stream`。FileCard / FileContentRenderer 的 _TextPreviewCard / ChatPage._pickFile 共用,作乐观消息的 mime 占位,server 端 `enhanceContentFromFile` 会用 files 表权威值覆盖
