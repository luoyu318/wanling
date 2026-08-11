# Server 数据层

internal/repository/ 10 个 repo(agent / approval / conversation / delivery / file / friendship / message / pairing / participant / user)+ internal/model/null_json.go 类型。

## repository 总览

数据库操作层。

## Repository 共用基础

`internal/repository/db.go` 除 `NewDB` 外，还提供 `queryExecutor` 封装：统一的 SQL 调用入口（queryRow / exec / query / beginTx），强制 ctx 消费（类型系统约束），CI lint `scripts/check-repo-ctx.sh` 检测违规。所有 repo 方法首参为 `ctx`，17 个 Tx 方法显式调 `*Context` 变体。

## ConversationRepo

`ListForUser`(JOIN conversation_participants + 多个 subquery 拼装 IM 风格列表,含 `last_message_*` 子查询实时算 + 撤回消息 CASE WHEN 改写 + sender 字段。**WHERE 只过滤 hidden_at IS NULL**(不再要求 EXISTS messages),让无消息会话(刚建群 / dm 刚 FindOrCreate)也立即返;`last_message_at` + ORDER BY 用 `COALESCE((子查询), c.created_at)` 兜底,避免 client 拿到 0001-01-01 零值)、`GetByID`(单查,**SELECT 含 `session_meta`**,mode/model 元数据走 plugin 写入后由本字段读出)、`GetLastVisibleMessage`(取某 user 视角最新可见消息,撤回也保留并改写 content)、`BatchLoadParticipantSummaries`(一次 SQL 批量查多个 conv 的 participants 摘要,List handler / buildDetail 都调它)、`FindOrCreateDM`(1-1 dm 按 type+双方 member 去重)、`CreateTx`(群聊创建)、`UpdateProfile`(更新群聊 title/avatar;agent 改名 `UpdateTitleAsAgent` 复用本方法,只传 title、avatar 空串)、**`UpdateSessionMeta(convID, meta []byte)`**(写 `conversations.session_meta` JSONB,plugin session.updated / vcs.branch.updated 同步入口,handler `UpdateSessionMetaAsAgent` 调用,schemaless 透传 cwd/git_branch 等新字段无需改)、`ListAgentSessionsForUser`(双 JOIN user+agent 过滤 `type=agent_session` 的二级列表查询,`ListAgentSessions` handler 用。**`last_agent_reply_content` 子查询**(2026-08-05):取 agent 最后一条**非 silent** 的 `text/markdown` 消息文本作会话简介,过滤 reasoning/step_finish/tool_card 等 silent 过程消息;2026-08-10 起聚合卡翻转后的 `aggregate_card` 也命中(读 `data.preview` = 回合结束摘要,由 set_silent 翻转时 server 写入),与 APP WS 实时派生规则对齐)。015 模型重构后不再读写 conversations.user_id / agent_id 等老字段(下沉到 conversation_participants)。

## ParticipantRepo

操作 `conversation_participants` 表。`AddParticipantsTx`（创建会话/邀请成员用，ON CONFLICT DO NOTHING 幂等）、`Exists`（权限校验，命中 PK 索引）、`Get`（单查）、`ListByConversation` / `ListByConversationTx`（事务版本，发消息用同事务读避免脏读）、`IncrUnreadTx`（发消息时给非 sender 全员 +1）、`Unhide`（清整个会话所有 participants 的 hidden_at，「新消息自动恢复显示」语义；发消息流程在 commit 之后调非事务版，原事务内 `UnhideTx` 触发 PG deadlock 已移出）、`MarkMessagesReadTx`（按 messageId 批量标已读 + 重算 unread_count + 更新 last_read_message_id）、`RecomputeUnreadForConvTx`（撤回时按 conv 维度重算全员 unread_count，跟 MarkMessagesReadTx 同口径）、`SetPinned` / `SetHidden`（个人维度置顶/隐藏）、`RemoveParticipantTx`（群踢人）/ `DestroyConversationTx`（解散）。

## MessageRepo

`CreateTx`（事务版创建消息）、`Get` / `GetByIDs`（不过滤 deleted_at，权限校验用）、`SoftDeleteTx`（事务版，撤回用，置 deleted_at=NOW()）、`HideForUser` / `HideForUsers`（写 message_hidden 表）、`IsHidden`（查某消息是否被某 participant 隐藏，引用块跳转 GetMessageContext 用，拒绝跳转到自己已隐藏的消息）、`ListBefore` / `CountBefore`（走 `idx_messages_conv_created` 游标分页）、`ListAfter`（向下加载新消息）、`GetMessageContextTx`（target + 前后 N 条，引用块跨页跳转用；before/after 过滤 deleted_at 撤回消息，target 不过滤由 handler 层显式 404）。撤回消息（deleted_at IS NOT NULL）也返，靠 SanitizeForClient 在 handler 出口改写 content 为 `{msg_type:recalled,data:{}}`，client 据此渲染占位卡片。

## DeliveryRepo

操作 `message_deliveries` 表（每条消息给每个 recipient 落一行）。`CreateBatchTx`（事务版批量插）、`FirstUnread`（按 conv 取未读首条，游标定位用）。

## FileRepo

文件 CRUD + `AddConvLink`（写 file_conv_links 幂等）+ `CheckAccess`（四档放行判定:IsOwner / IsUserAvatar / IsAgentAvatar / **IsConvAvatar**(conversations.avatar_url 命中) / IsConvParticipant,单 SQL 一次查清;IsAvatar() 联合判定三种头像命中即放行)。

## 老方法已删除

（功能下沉到 ParticipantRepo）。

## model/null_json.go

`NullJSON` 类型（实现 Scanner/Valuer/Marshaler/Unmarshaler），处理可空 JSONB 字段。**不要加 `omitempty` tag**（实现了 MarshalJSON 后 omitempty 是死代码）。
