# Server 支撑组件

文件存储 + 缩略图 + 配置 + 在线状态 + 审批状态机。

## storage

文件存储抽象，当前为本地存储，接口预留 MinIO 扩展。`Provider.SaveThumbnail(storageName, data)` 按指定名落盘缩略图字节（`LocalStorage` 实现写同 baseDir，文件名 `{原fileID}_thumb.jpg`）。

## imaging

图片缩略图生成（`golang.org/x/image/draw` Catmull-Rom 高质量缩放）。`GenerateThumbnail(reader)` 解码 jpeg/png/webp/gif → 按长边 600 等比缩放（不放大）→ 透明图填白底合成（JPEG 不支持 alpha）→ 编码 JPEG(q85) 返回 `(bytes, w, h, err)`；非图片解码失败返回 error 供上游 fail-soft。

## config

从环境变量加载配置，必填项（JWT_SECRET、DB_PASSWORD）缺失直接报错退出。JWTConfig 含 AccessTTL(默认 2h)/RefreshTTL(默认 30d)。

## presence

基于 Redis 的在线状态服务。`Online`/`RefreshTTL` 都用 **幂等 `SET`**（带 ttl）而非 `EXPIRE`：`EXPIRE` 对已失效的 key 返回 0 且不重建，会导致 Redis 清空或 server 重启后（既有 WS 连接不会断开）存活连接的 presence key 永久丢失，agent 表现为「离线但能正常收发消息」；`SET` 幂等且能重建 key，**下一次心跳即自愈**（commit 766f192 修复）。无 Redis 时降级为内存 map（多实例部署不生效）。

## approval

审批状态机编排层。`service.go` 的 `Decide` 是核心：JOIN 查审批+消息 → 校验 action_id 合法（question 的 answer 再校验 answers ∈ options / 单选限 1）→ `MarkDecided`（仅 allow_always 写 allow_pattern，其余决策显式清列防白名单污染 + `MatchAllowPattern` 加 decided_action 条件；deny/cancel/reject 统一映射 denied；question 的 answers 落 decided_answers）→ 双写 messages.content（state + decided_* + answers）→ 广播 MESSAGE_UPDATE（双端）+ APPROVAL_DECIDED（仅 agent，带 session_key + confirm_id + answers）。`cleanup.go` 的 `RunCleanup` 后台 goroutine 每 1 分钟扫超时审批（pending + expires_at < now）→ MarkExpired（复用 Decide 终态路径：双写 content state=expired + 广播 MESSAGE_UPDATE，APP 卡片不停留 pending）+ 广播 APPROVAL_EXPIRED。`*Service` 同时满足 `ExpiredFinder`/`Marker` 接口供 cleanup 调用。question 类型协议见 [../../ai-handbook/approval-card.md](../../ai-handbook/approval-card.md)。
