/// 图片内存缓存 key 统一约定。
///
/// Flutter 的 [ImageCache] 按 key 索引已解码的 bitmap。本项目有多处图片加载入口
/// （头像 / 消息缩略图 / markdown 内嵌图 / 画廊大图），若各用不同 key，同一张
/// 图会在内存里重复缓存多份，且互不命中——这正是「每次打开重新加载」的根因
/// 之一（缩略图缓存的 bitmap，画廊打开时用不同 key 取不到，要重新解码）。
///
/// 本文件统一 key 口径：
/// - [thumbCacheKey]：所有「缩略图场景」（消息列表 / 气泡 / markdown 内嵌图）
///   共用。指向服务端 ?thumb=1 的小图（长边 600px）。
/// - [originCacheKey]：画廊全屏大图独用。指向原图（高清）。与缩略图 key 隔离，
///   避免缩略图小 bitmap 把原图大 bitmap 从内存 LRU 里顶掉。
///
/// key 用稳定前缀（thumb_/origin_）+ fileId，不含 baseUrl/host——这样切换服务器
/// 或账号时，同一张图的内存缓存依然命中（fileId 全局唯一不变）。
library;

/// 缩略图场景的内存缓存 key（消息列表 / 气泡 / markdown 内嵌图共用）。
String thumbCacheKey(String fileId) => 'thumb_$fileId';

/// 原图场景的内存缓存 key（画廊全屏大图独用，与缩略图隔离）。
String originCacheKey(String fileId) => 'origin_$fileId';
