# Server 实时通道

WS 连接管理 + 消息事务处理 + dispatch 广播。

## hub

WebSocket 连接管理器，用 `sync.Map` 以 `role:id` 为 key 管理所有客户端连接，提供 `SendToUser` / `SendToAgent` / `SendToConv`（user+agent 双发，用于消息删除等多端同步广播）方法。**dispatch.go** 提供 3 个审批相关广播 helper：`BroadcastMessageUpdate`（双端，消息内容更新如审批决策后双写 content）、`SendApprovalDecided`（仅 agent，推决策结果带 session_key/confirm_id）、`SendApprovalExpired`（仅 agent，超时通知）。Hub 持有 `NextSeq()` 自增序列号（per-client 单调递增，供 dispatch 的 WSMessage.s 字段）。

## message/processor

消息处理器。`HandleIncoming` 用事务（BeginTx → CreateTx → DeliveryRepo.CreateBatchTx → ParticipantRepo.IncrUnreadTx → Commit）保证消息持久化和 unread_count 原子性，dispatch 在 commit 之后；`ParticipantRepo.Unhide`（非事务版）也在 commit 之后调用——原事务内 `UnhideTx` 与 `MarkMessagesReadTx` 并发会触发 PG deadlock(40P01)，已移出事务（幂等，SET NULL）。Unhide 清整个会话所有 participants 的 hidden_at（「新消息自动恢复显示」语义，修复「对方删过会话，我发消息后对方列表不显示」bug）。017 删 conversations 缓存字段后不再调 UpdateLastMessageTx（写路径零维护）。dispatch payload 含 `sender_name`（client 通知显示用）+ `sender_avatar_url`（bg-service 通知大头像主数据源，替代原依赖 UI IPC 同步的链路），两者均由 `senderDisplayName` / `senderAvatarURL` 在 dispatch 前查询填入，查询失败返空串 client fallback。返回 `*Message`（含 server id + created_at），供 send_handler HTTP 接口返给 client。

**`enhanceContentFromFile`**(v1.0.6,原 `enhanceImageContent` 泛化):消息持久化前从 files 表补字段。image 类型补 width/height(已有则幂等跳过);**file 类型补 file_size + mime_type**(从 files 表 Size / MimeType 字段读,client 乐观发送时只带 file_id 也能拿到权威值)。fail-soft:任何步骤失败(非 image/file 类型 / 无 file_id / files 表查不到 / data 结构异常)都返原 content 不阻断发送。client 端 FileCard 渲染依赖此字段决定文件大小显示和图标类型
